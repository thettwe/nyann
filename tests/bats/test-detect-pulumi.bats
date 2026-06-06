#!/usr/bin/env bats
# I3 — Pulumi support: detection + descriptor shape + discrimination edges.
#
# Asserts against the StackDescriptor emitted by bin/detect-stack.sh:
#   .archetype == "infra", .framework == "pulumi" (SHORT tag),
#   .iac.tool == "pulumi" (LONG enum), .iac.language from runtime:,
#   .iac.units[] (kind=stack from Pulumi.<stack>.yaml), .iac.var_files (same
#   stack files). Also exercises the precedence guarantees that protect Pulumi
#   detection's neighbours (helm/ansible/cdk/k8s) and a negative case so a
#   non-Pulumi repo is never mis-tagged pulumi.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-pulumi.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

# Helper: run the full stack detector against the staged $REPO.
_detect() { bash "$REPO_ROOT/bin/detect-stack.sh" --path "$REPO"; }

# --- core Pulumi detection --------------------------------------------------

@test "Pulumi.yaml (nodejs runtime): infra + framework pulumi + iac.tool pulumi + language typescript" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: nodejs
EOF
  out=$(_detect)
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "pulumi"'
  echo "$out" | jq -e '.iac.tool == "pulumi"'
  echo "$out" | jq -e '.iac.language == "typescript"'
}

@test "Pulumi.yaml python runtime → iac.language python" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: python
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "pulumi"'
  echo "$out" | jq -e '.iac.language == "python"'
}

@test "Pulumi.yaml go runtime → iac.language go" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: go
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.language == "go"'
}

@test "Pulumi.yaml dotnet runtime → iac.language csharp" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: dotnet
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.language == "csharp"'
}

@test "Pulumi.yml (alt extension) is recognized" {
  cat > "$REPO/Pulumi.yml" <<'EOF'
name: myinfra
runtime: nodejs
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "pulumi"'
}

@test "Pulumi with unrecognized runtime: iac present but language omitted" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: java
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "pulumi"'
  # language could not be inferred → key omitted entirely (guard with has()).
  echo "$out" | jq -e '(.iac | has("language")) == false'
}

# --- stack discovery + var_files --------------------------------------------

@test "Pulumi.<stack>.yaml files become kind=stack units AND var_files" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: nodejs
EOF
  cat > "$REPO/Pulumi.dev.yaml" <<'EOF'
config:
  myinfra:region: us-east-1
EOF
  cat > "$REPO/Pulumi.prod.yaml" <<'EOF'
config:
  myinfra:dbPassword:
    secure: AAABAExampleCipherText==
EOF
  out=$(_detect)
  # Two stacks discovered.
  echo "$out" | jq -e '[.iac.units[] | select(.kind == "stack")] | length == 2'
  echo "$out" | jq -e 'any(.iac.units[]; .kind == "stack" and .name == "dev")'
  echo "$out" | jq -e 'any(.iac.units[]; .kind == "stack" and .name == "prod")'
  # The project manifest itself is NOT a stack unit.
  echo "$out" | jq -e 'any(.iac.units[]; .name == "Pulumi") == false'
  # Each stack file is also recorded as a var_file (secret-scan target).
  echo "$out" | jq -e '.iac.var_files | index("Pulumi.dev.yaml")'
  echo "$out" | jq -e '.iac.var_files | index("Pulumi.prod.yaml")'
  echo "$out" | jq -e '(.iac.var_files | index("Pulumi.yaml")) == null'
}

@test "Pulumi stack unit version is null (stacks aren't independently versioned here)" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: nodejs
EOF
  cat > "$REPO/Pulumi.dev.yaml" <<'EOF'
config: {}
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.units[] | select(.kind=="stack" and .name=="dev") | .version == null'
}

@test "Pulumi project with no stack files: units empty, still pulumi" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: myinfra
runtime: nodejs
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "pulumi"'
  echo "$out" | jq -e '.iac.units == []'
  echo "$out" | jq -e '.iac.var_files == []'
}

# --- precedence guarantees (the spec's discrimination edges) ----------------
# These confirm Pulumi detection does not steal repos that belong to higher- or
# lower-precedence tools, and vice-versa.

@test "Helm chart (Chart.yaml + templates/) → helm, NOT pulumi/kubernetes" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 0.1.0
EOF
  mkdir -p "$REPO/templates"
  echo 'kind: Deployment' > "$REPO/templates/deploy.yaml"
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "helm"'
  echo "$out" | jq -e '.framework == "helm"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "Ansible top-level playbook .yml → ansible, NOT kubernetes" {
  cat > "$REPO/site.yml" <<'EOF'
- hosts: all
  tasks:
    - name: ping
      ping:
EOF
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "ansible"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "CDK app: language inferred from cdk.json .app field (python)" {
  cat > "$REPO/cdk.json" <<'EOF'
{ "app": "python3 app.py" }
EOF
  mkdir -p "$REPO/lib"
  echo '# stack' > "$REPO/lib/my-stack.py"
  out=$(_detect)
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.language == "python"'
}

@test "Bare K8s manifest under .github/ is EXCLUDED (CI yaml, not k8s)" {
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yml" <<'EOF'
apiVersion: v1
kind: ConfigMap
EOF
  out=$(_detect)
  # The only apiVersion:+kind: yaml lives under .github/, which the bare-k8s
  # detector excludes → repo is NOT classified as infra at all.
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e '(.iac.tool // "") != "kubernetes"'
}

# --- NEGATIVE: a non-Pulumi repo must never be tagged pulumi ----------------

@test "NEGATIVE: plain Node app (package.json, no Pulumi.yaml) is NOT pulumi" {
  cat > "$REPO/package.json" <<'EOF'
{ "name": "webapp", "version": "1.0.0" }
EOF
  echo 'console.log("hi");' > "$REPO/index.js"
  out=$(_detect)
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e '(.framework // "") != "pulumi"'
  # No iac block at all for a non-IaC repo.
  echo "$out" | jq -e 'has("iac") == false'
}

@test "NEGATIVE: a YAML config repo with no Pulumi.yaml is NOT pulumi" {
  cat > "$REPO/config.yaml" <<'EOF'
name: just-config
some: value
EOF
  out=$(_detect)
  echo "$out" | jq -e '(.framework // "") != "pulumi"'
  echo "$out" | jq -e '(.iac.tool // "") != "pulumi"'
}

# --- profile + hook surface --------------------------------------------------

@test "pulumi-app profile validates against profiles/_schema.json" {
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  elif command -v uvx >/dev/null 2>&1; then
    VALIDATE=(uvx --quiet check-jsonschema)
  else
    skip "no schema validator"
  fi
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/profiles/_schema.json" "$REPO_ROOT/profiles/pulumi-app.json"
}

@test "pulumi-app profile is infra + framework pulumi + pulumi-preview-check hook" {
  jq -e '.archetype == "infra"'                              "$REPO_ROOT/profiles/pulumi-app.json"
  jq -e '.stack.framework == "pulumi"'                       "$REPO_ROOT/profiles/pulumi-app.json"
  jq -e '.iac.tool == "pulumi"'                              "$REPO_ROOT/profiles/pulumi-app.json"
  jq -e '.hooks.pre_commit | index("pulumi-preview-check")'  "$REPO_ROOT/profiles/pulumi-app.json"
}

@test "pulumi-preview-check hook soft-skips when pulumi CLI missing" {
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/pulumi/pulumi-preview-check.sh" 2>&1 )
  echo "$out" | grep -q "pulumi not installed"
}
