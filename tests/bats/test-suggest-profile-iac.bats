#!/usr/bin/env bats
# bin/suggest-profile.sh — IaC profile recommendation (v1.13.0 INC-1).
#
# Locks the framework-tag <-> profile alignment for every IaC stack: a repo
# detected as a given IaC tool MUST surface its matching starter profile as
# the top suggestion (with a +40 framework match). This guards two non-obvious
# tag mappings that a green detection suite would otherwise miss:
#   - aws-cdk: descriptor framework="cdk" (short) must match aws-cdk-app.
#   - kustomize: descriptor framework="kubernetes" (kubernetes-app covers both
#     bare-manifest and kustomize layouts) must match kubernetes-app.
# Both were live bugs caught only because this test exercises the full
# detect -> suggest path, not just detection output.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUGGEST="${REPO_ROOT}/bin/suggest-profile.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

# top suggestion name for the staged repo
_top() {
  bash "$SUGGEST" --target "$REPO" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -r '.suggestions[0].name' "$TMP/out.json"
}

@test "AWS CDK (TypeScript) repo → aws-cdk-app is top suggestion" {
  printf '{\n  "app": "npx ts-node bin/app.ts"\n}\n' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib"
  printf 'export class FooStack {}\n' > "$REPO/lib/foo-stack.ts"
  [ "$(_top)" = "aws-cdk-app" ]
}

@test "AWS CDK (Python) repo → aws-cdk-app is top suggestion" {
  printf '{\n  "app": "python3 app.py"\n}\n' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib"
  printf 'class FooStack: pass\n' > "$REPO/lib/foo_stack.py"
  [ "$(_top)" = "aws-cdk-app" ]
}

@test "Pulumi repo → pulumi-app is top suggestion" {
  printf 'name: infra\nruntime: nodejs\n' > "$REPO/Pulumi.yaml"
  printf 'config: {}\n' > "$REPO/Pulumi.dev.yaml"
  [ "$(_top)" = "pulumi-app" ]
}

@test "Helm chart → helm-chart is top suggestion" {
  printf 'apiVersion: v2\nname: widget\nversion: 0.1.0\n' > "$REPO/Chart.yaml"
  printf 'replicaCount: 1\n' > "$REPO/values.yaml"
  mkdir -p "$REPO/templates"
  [ "$(_top)" = "helm-chart" ]
}

@test "Kustomize repo → kubernetes-app is top suggestion (framework maps to kubernetes)" {
  printf 'resources:\n  - deployment.yaml\n' > "$REPO/kustomization.yaml"
  [ "$(_top)" = "kubernetes-app" ]
}

@test "Bare Kubernetes manifests → kubernetes-app is top suggestion" {
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: widget\n' > "$REPO/deployment.yaml"
  [ "$(_top)" = "kubernetes-app" ]
}

@test "Ansible playbook → ansible-playbook is top suggestion" {
  printf -- '- hosts: all\n  tasks:\n    - debug: msg=hi\n' > "$REPO/site.yml"
  printf '[defaults]\n' > "$REPO/ansible.cfg"
  [ "$(_top)" = "ansible-playbook" ]
}

@test "every IaC suggestion carries a framework match reason (not language-only)" {
  printf '{\n  "app": "npx ts-node bin/app.ts"\n}\n' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib"
  printf 'export class FooStack {}\n' > "$REPO/lib/foo-stack.ts"
  bash "$SUGGEST" --target "$REPO" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  # The top (aws-cdk-app) must have won via a framework match, not just yaml/ts
  # language affinity — assert a framework-match reason is present.
  jq -e '.suggestions[0].reasons | any(test("framework match"))' "$TMP/out.json" >/dev/null
}
