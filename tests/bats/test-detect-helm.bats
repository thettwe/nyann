#!/usr/bin/env bats
# I5 — Helm chart support: detection (bin/detect-stack/detect-iac.sh via
# bin/detect-stack.sh) + the helm-chart profile + the per-tool hook scripts.
#
# Asserts against the descriptor's `iac` block shape emitted by detect-stack.sh:
#   .archetype == "infra", .framework == "helm", .primary_language == "yaml",
#   .iac.tool == "helm", .iac.language == "yaml", .iac.units[] (kind=chart),
#   .iac.lockfiles, .iac.var_files.
# Also covers the precedence/discrimination guarantees from the v1.13.0 spec
# (Chart.yaml short-circuits before bare-k8s; ansible playbook .yml is NOT
# k8s; cdk language inferred from cdk.json .app; .github/ yaml excluded from
# k8s) and a NEGATIVE case (a plain library repo is NOT classified as helm).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-helm.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

# --- helpers ---------------------------------------------------------------

# Write a minimal single chart (Chart.yaml + values.yaml + templates/).
_make_single_chart() {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 1.2.3
appVersion: "4.5.6"
EOF
  echo 'replicaCount: 1' > "$REPO/values.yaml"
  mkdir -p "$REPO/templates"
  cat > "$REPO/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
EOF
}

# --- detection: single chart ----------------------------------------------

@test "single chart (Chart.yaml + values.yaml + templates/): tool helm, language yaml" {
  _make_single_chart
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "helm"'
  echo "$out" | jq -e '.primary_language == "yaml"'
  echo "$out" | jq -e '.iac.tool == "helm"'
  echo "$out" | jq -e '.iac.language == "yaml"'
}

@test "single chart: root chart unit kind=chart with version from Chart.yaml" {
  _make_single_chart
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  # Exactly one unit, kind chart, path '.', name + version from Chart.yaml.
  echo "$out" | jq -e '(.iac.units | length) == 1'
  echo "$out" | jq -e '.iac.units[0].kind == "chart"'
  echo "$out" | jq -e '.iac.units[0].path == "."'
  echo "$out" | jq -e '.iac.units[0].name == "my-chart"'
  echo "$out" | jq -e '.iac.units[0].version == "1.2.3"'
}

@test "chart via templates/ only (no values.yaml): still helm" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: tpl-only
version: 0.1.0
EOF
  mkdir -p "$REPO/templates"
  echo 'apiVersion: v1
kind: ConfigMap' > "$REPO/templates/cm.yaml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
}

@test "chart via values.yml (alternate extension): still helm" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: yml-values
version: 0.2.0
EOF
  echo 'replicaCount: 1' > "$REPO/values.yml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
}

# --- detection: umbrella chart with subcharts ------------------------------

@test "umbrella chart: root '.' + charts/* subcharts as chart units" {
  _make_single_chart
  mkdir -p "$REPO/charts/sub-a" "$REPO/charts/sub-b"
  cat > "$REPO/charts/sub-a/Chart.yaml" <<'EOF'
apiVersion: v2
name: sub-a
version: 0.4.0
EOF
  cat > "$REPO/charts/sub-b/Chart.yaml" <<'EOF'
apiVersion: v2
name: sub-b
version: 0.5.0
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
  # Root chart + 2 subcharts = 3 units, all kind=chart.
  echo "$out" | jq -e '(.iac.units | length) == 3'
  echo "$out" | jq -e '[.iac.units[].kind] | all(. == "chart")'
  # Root present at '.'.
  echo "$out" | jq -e 'any(.iac.units[]; .path == ".")'
  # Subchart paths + versions surfaced.
  echo "$out" | jq -e 'any(.iac.units[]; .path == "charts/sub-a" and .name == "sub-a" and .version == "0.4.0")'
  echo "$out" | jq -e 'any(.iac.units[]; .path == "charts/sub-b" and .name == "sub-b" and .version == "0.5.0")'
}

@test "Chart.lock present: recorded in iac.lockfiles" {
  _make_single_chart
  echo 'dependencies: []' > "$REPO/Chart.lock"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.lockfiles | index("Chart.lock")'
}

@test "no Chart.lock: iac.lockfiles is empty" {
  _make_single_chart
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '(.iac.lockfiles | length) == 0'
}

# --- precedence / discrimination edge cases --------------------------------

@test "Chart.yaml with k8s-looking templates: classified helm, NOT plain kubernetes" {
  # The chart's templates/ holds manifests with apiVersion:+kind:. Helm
  # precedence (step 1) must short-circuit before bare-k8s (step 7).
  _make_single_chart
  echo 'apiVersion: v1
kind: Service
metadata:
  name: svc' > "$REPO/templates/service.yaml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
  echo "$out" | jq -e '.framework == "helm"'
}

@test "kustomization.yaml present alongside Chart.yaml: Chart.yaml wins (helm)" {
  # Helm (step 1) outranks kustomize (step 2).
  _make_single_chart
  echo 'resources:
  - deployment.yaml' > "$REPO/kustomization.yaml"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
}

@test "Ansible playbook .yml is classified ansible, NOT kubernetes" {
  # Discrimination guarantee: a playbook (hosts: + tasks:) lacks
  # apiVersion:+kind:, so bare-k8s (step 7) never claims it; ansible (step 6)
  # does. No Chart.yaml here, so helm is out of the picture.
  cat > "$REPO/site.yml" <<'EOF'
- hosts: all
  tasks:
    - name: ping
      ansible.builtin.ping:
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "ansible"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "CDK language inferred from cdk.json .app field (python)" {
  # cdk (step 4) infers language from the app field, NOT helm. Confirms the
  # per-tool language read the spec describes.
  echo '{"app":"python3 app.py"}' > "$REPO/cdk.json"
  mkdir -p "$REPO/lib"
  echo '# stack' > "$REPO/lib/foo-stack.py"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.language == "python"'
}

@test "K8s detection excludes .github/ workflow yaml (CI false-positive guard)" {
  # A repo whose ONLY apiVersion:+kind: yaml lives under .github/ must not be
  # classified as kubernetes — confirms the CI-path exclusion the spec
  # requires. No Chart.yaml/kustomization here, so this exercises step 7.
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yml" <<'EOF'
apiVersion: v1
kind: Workflow
name: ci
EOF
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e '(.iac == null) or (.iac.tool != "kubernetes")'
}

# --- NEGATIVE case ---------------------------------------------------------

@test "plain library repo (no Chart.yaml): NOT classified as helm / not infra" {
  # A non-IaC repo: no iac block at all, archetype is not infra, framework not
  # helm. Guards against helm over-triggering.
  echo '{"name":"lib","version":"1.0.0"}' > "$REPO/package.json"
  echo 'export const x = 1;' > "$REPO/index.ts"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e '.framework != "helm"'
  echo "$out" | jq -e '(.iac == null) or (.iac.tool != "helm")'
}

@test "non-helm IaC repo (terraform) is NOT classified as helm" {
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out=$(bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO")
  echo "$out" | jq -e '.iac.tool == "terraform"'
  echo "$out" | jq -e '.iac.tool != "helm"'
}

# --- profile ---------------------------------------------------------------

@test "helm-chart profile validates against profiles/_schema.json" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  run bash "$REPO_ROOT/bin/validate-profile.sh" "$REPO_ROOT/profiles/helm-chart.json"
  [ "$status" -eq 0 ]
}

@test "helm-chart profile declares helm-lint + helm-template-check pre_commit hooks" {
  jq -e '.hooks.pre_commit | index("helm-lint")'           "$REPO_ROOT/profiles/helm-chart.json"
  jq -e '.hooks.pre_commit | index("helm-template-check")' "$REPO_ROOT/profiles/helm-chart.json"
}

@test "helm-chart profile pins iac.tool helm + a chart unit" {
  # NOTE: the descriptor's runtime primary_language is "yaml" (asserted in the
  # detection tests above), but the profile schema's stack.primary_language
  # enum has no "yaml" member, so the static profile uses "unknown" — the
  # archetype/framework/iac.tool carry the helm signal.
  jq -e '.archetype == "infra"'           "$REPO_ROOT/profiles/helm-chart.json"
  jq -e '.stack.framework == "helm"'      "$REPO_ROOT/profiles/helm-chart.json"
  jq -e '.iac.tool == "helm"'             "$REPO_ROOT/profiles/helm-chart.json"
  jq -e 'any(.iac.units[]; .kind == "chart")' "$REPO_ROOT/profiles/helm-chart.json"
}

# --- hook scripts: soft-skip-when-CLI-absent -------------------------------

@test "helm-lint.sh soft-skips (exit 0) when helm CLI missing" {
  run env PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/helm/helm-lint.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "helm not installed"
}

@test "helm-template-check.sh soft-skips (exit 0) when helm CLI missing" {
  run env PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/helm/helm-template-check.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "helm not installed"
}
