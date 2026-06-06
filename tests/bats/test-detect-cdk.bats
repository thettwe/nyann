#!/usr/bin/env bats
# bin/detect-stack/detect-iac.sh — AWS CDK detection (I2) + the cross-tool
# discrimination edge cases the precedence ladder guarantees.
#
# Asserts the iac emit shape that detect-stack.sh produces for infra repos:
#   .archetype == "infra"
#   .framework == "cdk"          (SHORT producer tag — never "aws-cdk")
#   .iac.tool  == "aws-cdk"      (LONG schema enum value)
#   .iac.language inferred from cdk.json `app` (guarded with has() for the
#                 unrecognized-app edge case where it is omitted)
#   .iac.units[] kind=stack from the lib/*-stack.* + bin/*.{ts,py} globs
# plus the aws-cdk-app starter profile + its CDK hook scripts.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-cdk.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

# --- detection: language inference per cdk.json `app` field ----------------

@test "cdk.json (ts-node app) → infra, framework cdk, tool aws-cdk, language typescript" {
  echo '{"app":"npx ts-node --prefer-ts-exts bin/app.ts"}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.iac.language == "typescript"'
}

@test "cdk.json (python3 app) → language python" {
  echo '{"app":"python3 app.py"}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.iac.language == "python"'
}

@test "cdk.json (dotnet app) → language csharp" {
  echo '{"app":"dotnet run --project src/App"}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.language == "csharp"'
}

@test "cdk.json (go run app) → language go" {
  echo '{"app":"go run ."}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.language == "go"'
}

@test "cdk.json with unrecognized app field → still CDK, language omitted (not guessed)" {
  # Edge case from the spec: an unrecognized `app` leaves the language
  # un-inferred. The descriptor must OMIT .iac.language entirely rather than
  # emit an empty string — assert with has().
  echo '{"app":"./run-somehow"}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.iac | has("language") == false'
}

# --- detection: stack unit discovery via glob fallback ---------------------

@test "stacks discovered via lib/*-stack.ts + bin/*.ts glob (kind=stack, version null)" {
  echo '{"app":"npx ts-node bin/app.ts"}' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib" "$REPO/bin"
  echo 'export class FooStack {}' > "$REPO/lib/foo-stack.ts"
  echo 'export class BarStack {}' > "$REPO/lib/bar-stack.ts"
  echo '#!/usr/bin/env node' > "$REPO/bin/app.ts"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  # All discovered units are stacks.
  echo "$out" | jq -e '[.iac.units[]?.kind] | all(. == "stack")'
  # Names are basename-minus-extension; the lib stacks are present.
  echo "$out" | jq -e '[.iac.units[]?.name] | index("foo-stack") != null'
  echo "$out" | jq -e '[.iac.units[]?.name] | index("bar-stack") != null'
  echo "$out" | jq -e '[.iac.units[]?.name] | index("app") != null'
  # version is null (CDK stacks are not independently versioned here).
  echo "$out" | jq -e '[.iac.units[]?.version] | all(. == null)'
}

@test "cdk.json with no stack files → CDK detected, units array empty (not absent)" {
  echo '{"app":"npx ts-node bin/app.ts"}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.iac.units == []'
}

@test "CDK descriptor declares no lockfiles or var_files" {
  echo '{"app":"npx ts-node bin/app.ts"}' > "$REPO/cdk.json"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.lockfiles == []'
  echo "$out" | jq -e '.iac.var_files == []'
}

@test "CDK detected inside a monorepo subdir (cdk.json under infra/)" {
  mkdir -p "$REPO/infra/lib"
  echo '{"app":"npx ts-node bin/app.ts"}' > "$REPO/infra/cdk.json"
  echo 'export class NetStack {}' > "$REPO/infra/lib/net-stack.ts"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO/infra")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
}

# --- negative: a non-CDK repo is NOT classified as CDK ---------------------

@test "plain TypeScript library (no cdk.json) → NOT CDK, no iac block" {
  mkdir -p "$REPO/src"
  echo '{"name":"lib","version":"1.0.0"}' > "$REPO/package.json"
  echo 'export const x = 1;' > "$REPO/src/index.ts"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.framework != "cdk"'
  echo "$out" | jq -e '(.iac.tool // "") != "aws-cdk"'
  echo "$out" | jq -e 'has("iac") == false'
}

@test "empty repo → not infra, no CDK" {
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e 'has("iac") == false'
}

# --- precedence / cross-tool discrimination (spec edge cases) --------------

@test "discrimination: Helm chart (Chart.yaml + templates/) is helm, NOT plain kubernetes" {
  # Step 1 (helm) short-circuits before step 7 (bare-k8s) even though the
  # templates/ dir holds k8s-looking manifests.
  printf 'apiVersion: v2\nname: my-chart\nversion: 0.1.0\n' > "$REPO/Chart.yaml"
  mkdir -p "$REPO/templates"
  printf 'apiVersion: apps/v1\nkind: Deployment\n' > "$REPO/templates/deploy.yaml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "discrimination: Ansible playbook .yml is ansible, NOT kubernetes" {
  # A play (hosts: + tasks:) lacks apiVersion:/kind:, and step 6 (ansible)
  # precedes step 7 (bare-k8s), so it must classify as ansible.
  printf -- '- hosts: all\n  tasks:\n    - debug:\n        msg: hi\n' > "$REPO/site.yml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "ansible"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "discrimination: CI YAML under .github/ is NOT classified as kubernetes infra" {
  # apiVersion:+kind:-bearing YAML that lives only under .github/ is excluded
  # from the bare-k8s scan, so the repo is not flagged as infra.
  mkdir -p "$REPO/.github/workflows"
  printf 'apiVersion: 1\nkind: Workflow\n' > "$REPO/.github/workflows/ci.yml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e '(.iac.tool // "") != "kubernetes"'
}

# --- profile + hooks --------------------------------------------------------

@test "aws-cdk-app profile is valid against the profile schema" {
  run bash "$REPO_ROOT/bin/validate-profile.sh" "$REPO_ROOT/profiles/aws-cdk-app.json"
  [ "$status" -eq 0 ]
}

@test "aws-cdk-app profile: infra archetype, aws-cdk framework, npm pm, pinned iac.tool" {
  jq -e '.archetype == "infra"'             "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.stack.framework == "aws-cdk"'     "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.stack.primary_language == "typescript"' "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.stack.package_manager == "npm"'   "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.iac.tool == "aws-cdk"'            "$REPO_ROOT/profiles/aws-cdk-app.json"
}

@test "aws-cdk-app profile: cdk-synth-check + lint hooks and infra doc scaffolds" {
  jq -e '.hooks.pre_commit | index("cdk-synth-check")' "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.hooks.pre_commit | index("eslint")'          "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.documentation.scaffold_types | index("architecture")' "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.documentation.scaffold_types | index("runbook")'      "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.documentation.scaffold_types | index("deployment")'   "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.documentation.scaffold_types | index("adrs")'         "$REPO_ROOT/profiles/aws-cdk-app.json"
  jq -e '.documentation.scaffold_types | index("glossary")'     "$REPO_ROOT/profiles/aws-cdk-app.json"
}

@test "CDK hook scripts live at the per-tool subdir and are executable" {
  [ -x "$REPO_ROOT/templates/hooks/iac/cdk/cdk-synth-check.sh" ]
  [ -x "$REPO_ROOT/templates/hooks/iac/cdk/cdk-diff.sh" ]
}

@test "cdk-synth-check soft-skips when cdk CLI is missing" {
  # Run under a PATH that excludes any real cdk binary.
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/cdk/cdk-synth-check.sh" 2>&1 )
  echo "$out" | grep -q "cdk CLI not installed"
}

@test "cdk-diff is advisory: soft-skips (exit 0) when cdk CLI is missing" {
  run env PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/cdk/cdk-diff.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "cdk CLI not installed"
}

@test "iac-cdk pre-commit template wires the cdk-synth-check hook entry" {
  grep -q "cdk-synth-check" "$REPO_ROOT/templates/pre-commit-configs/iac-cdk.yaml"
  grep -q ".nyann/hooks/iac/cdk/cdk-synth-check.sh" "$REPO_ROOT/templates/pre-commit-configs/iac-cdk.yaml"
}
