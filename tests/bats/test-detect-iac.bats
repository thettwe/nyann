#!/usr/bin/env bats
# bin/detect-stack/detect-iac.sh + terraform-monorepo profile + IaC
# install-hooks phase.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-iac.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

@test "*.tf at root: archetype infra, framework terraform" {
  cat > "$REPO/main.tf" <<'EOF'
resource "null_resource" "x" {}
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "terraform"'
}

@test "*.tf only under modules/: archetype infra (priority over library)" {
  mkdir -p "$REPO/modules/network"
  echo 'resource "null_resource" "x" {}' > "$REPO/modules/network/main.tf"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "terraform"'
}

@test "cdk.json present → archetype infra" {
  echo '{"app":"node"}' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib"
  echo 'export const x = 1;' > "$REPO/lib/stack.ts"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
}

@test "Pulumi.yaml present → archetype infra" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: nodejs
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
}

@test "Chart.yaml + templates/ present → archetype infra" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 0.1.0
EOF
  mkdir -p "$REPO/templates"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
}

@test "Chart.yaml + values.yaml present → archetype infra" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 0.1.0
EOF
  echo 'replicaCount: 1' > "$REPO/values.yaml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
}

@test "bare Chart.yaml (no values/templates) → NOT classified as helm infra" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 0.1.0
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
}

@test "kustomization.yaml present → archetype infra" {
  cat > "$REPO/kustomization.yaml" <<'EOF'
resources:
  - deployment.yaml
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
}

@test "Deep monorepo: infrastructure/modules/aws/networking/main.tf detected" {
  mkdir -p "$REPO/infrastructure/modules/aws/networking"
  echo 'resource "null_resource" "x" {}' > "$REPO/infrastructure/modules/aws/networking/main.tf"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "terraform"'
}

@test "Empty repo: archetype unknown (not infra)" {
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  archetype=$(echo "$out" | jq -r '.archetype')
  [ "$archetype" != "infra" ]
}

@test "terraform-monorepo profile loads and validates" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/profiles/_schema.json" "$REPO_ROOT/profiles/terraform-monorepo.json"
}

@test "terraform-monorepo profile has expected pre_commit hooks" {
  jq -e '.hooks.pre_commit | index("terraform-fmt")'     "$REPO_ROOT/profiles/terraform-monorepo.json"
  jq -e '.hooks.pre_commit | index("terraform-validate")' "$REPO_ROOT/profiles/terraform-monorepo.json"
  jq -e '.hooks.pre_commit | index("tflint")'             "$REPO_ROOT/profiles/terraform-monorepo.json"
  jq -e '.hooks.pre_commit | index("tfsec")'              "$REPO_ROOT/profiles/terraform-monorepo.json"
  jq -e '.hooks.pre_commit | index("terraform-docs")'     "$REPO_ROOT/profiles/terraform-monorepo.json"
}

@test "IaC hook scripts: terraform-fmt soft-skips when terraform missing" {
  # Run under a PATH that excludes any real terraform binary.
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/terraform-fmt.sh" 2>&1 )
  echo "$out" | grep -q "terraform CLI not installed"
}

@test "IaC hook scripts: tflint soft-skips when tflint missing" {
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/tflint.sh" 2>&1 )
  echo "$out" | grep -q "tflint not installed"
}

@test "terraform-docs hook does not auto-stage READMEs of un-staged modules" {
  cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p modules/staged modules/untouched
  echo 'resource "null_resource" "s" {}' > modules/staged/main.tf
  echo 'resource "null_resource" "u" {}' > modules/untouched/main.tf
  echo "# staged module" > modules/staged/README.md
  echo "# untouched module" > modules/untouched/README.md
  git add modules/staged/main.tf modules/staged/README.md \
          modules/untouched/main.tf modules/untouched/README.md
  git -c core.hooksPath=/dev/null commit -q -m "feat: initial"

  # Modify both READMEs; stage only the staged-module's .tf change.
  printf '\nadded\n' >> modules/staged/README.md
  printf '\nadded\n' >> modules/untouched/README.md
  printf '\n# new\n' >> modules/staged/main.tf
  git add modules/staged/main.tf

  # Run the hook with no terraform-docs binary. It should soft-skip the
  # regeneration AND must not stage modules/untouched/README.md.
  PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/terraform-docs.sh" \
    >/dev/null 2>&1 || true

  staged_now=$( git diff --cached --name-only | sort | tr '\n' ' ' )
  case "$staged_now" in
    *"modules/untouched/README.md"*)
      echo "untouched README was auto-staged: $staged_now" >&2
      false
      ;;
  esac
}

@test "infra archetype scaffold map emits IaC-appropriate doc types" {
  out=$( bash -c "source '$REPO_ROOT/bin/_lib.sh'; nyann::archetype_scaffold_map infra" )
  echo "$out" | grep -q "^architecture:"
  echo "$out" | grep -q "^runbook:"
  echo "$out" | grep -q "^deployment:"
  echo "$out" | grep -q "^adrs:"
}

@test "install-hooks --iac copies IaC wrapper scripts into .nyann/hooks/iac" {
  cd "$REPO" && git init -q -b main
  run bash "$REPO_ROOT/bin/install-hooks.sh" --target "$REPO" --iac --no-install-hook
  [ "$status" -eq 0 ]
  [ -x "$REPO/.nyann/hooks/iac/terraform-fmt.sh" ]
  [ -x "$REPO/.nyann/hooks/iac/terraform-validate.sh" ]
  [ -x "$REPO/.nyann/hooks/iac/tflint.sh" ]
  [ -x "$REPO/.nyann/hooks/iac/tfsec.sh" ]
  [ -x "$REPO/.nyann/hooks/iac/terraform-docs.sh" ]
  [ -f "$REPO/.pre-commit-config.yaml" ]
  grep -q "terraform-fmt" "$REPO/.pre-commit-config.yaml"
}

@test "install-hooks --iac is listed in the phase help and accepted in the no-phase warn" {
  # No phase → warn includes --iac in the list.
  cd "$REPO" && git init -q -b main
  run bash "$REPO_ROOT/bin/install-hooks.sh" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--iac"
}
