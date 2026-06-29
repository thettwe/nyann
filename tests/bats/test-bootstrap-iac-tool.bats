#!/usr/bin/env bats
# bin/bootstrap.sh — the IaC hook phase must pass --iac-tool to install-hooks
# so the per-tool hook set (helm/cdk/k8s/pulumi/ansible) is materialized, not
# the terraform default. Regression lock for v1.13.0 INC-1: bootstrap used to
# add --iac with no tool, silently installing the terraform hook set for EVERY
# infra repo (the per-tool dispatch was unreachable from the real bootstrap).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  TMP=$(mktemp -d -t nyann-iactool.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
}

teardown() { rm -rf "$TMP"; }

plan_sha() { bash "$PREVIEW" --plan "$1" --emit-sha256 2>/dev/null; }

# Run bootstrap in --dry-run and return the planned install-hooks command line
# (bootstrap logs "DRY-RUN: bin/install-hooks.sh ..." with the full arg set).
_dryrun_hook_cmd() {
  local profile="$1"
  bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
  bash "$REPO_ROOT/bin/route-docs.sh" --profile "$profile" > "$TMP/docplan.json" 2>/dev/null \
    || echo '{}' > "$TMP/docplan.json"
  bash "$BOOTSTRAP" --dry-run \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$profile" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" 2>&1 | grep -F "DRY-RUN: bin/install-hooks.sh"
}

@test "Helm repo bootstrap passes --iac-tool helm" {
  printf 'apiVersion: v2\nname: widget\nversion: 0.1.0\n' > "$REPO/Chart.yaml"
  printf 'replicaCount: 1\n' > "$REPO/values.yaml"
  mkdir -p "$REPO/templates"
  out=$(_dryrun_hook_cmd "${REPO_ROOT}/profiles/helm-chart.json")
  echo "$out" | grep -Fq -- '--iac'
  echo "$out" | grep -Fq -- '--iac-tool helm'
}

@test "AWS CDK repo bootstrap passes --iac-tool aws-cdk" {
  printf '{ "app": "npx ts-node bin/app.ts" }\n' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib"
  printf 'export class FooStack {}\n' > "$REPO/lib/foo-stack.ts"
  out=$(_dryrun_hook_cmd "${REPO_ROOT}/profiles/aws-cdk-app.json")
  echo "$out" | grep -Fq -- '--iac-tool aws-cdk'
}

@test "Terraform repo bootstrap enables --iac with terraform tool (not a wrong tool)" {
  printf 'resource "null_resource" "x" {}\n' > "$REPO/main.tf"
  out=$(_dryrun_hook_cmd "${REPO_ROOT}/profiles/terraform-monorepo.json")
  echo "$out" | grep -Fq -- '--iac'
  # Must not mis-pass a non-terraform tool.
  ! echo "$out" | grep -Eq -- '--iac-tool (helm|aws-cdk|pulumi|ansible|kustomize|kubernetes)'
}
