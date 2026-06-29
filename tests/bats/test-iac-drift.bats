#!/usr/bin/env bats
# bin/iac-drift-scan.sh + the 4 detectors (unpinned-refs, missing-lockfile,
# secrets-in-vars, version-lag).
#
# Mirrors tests/bats/test-docs-drift.bats: per-test ephemeral git repo so
# git tag / git commit / git check-ignore semantics are real.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-iac-drift.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

# Commit every working-tree change so the committed-only secrets gate sees
# tracked files.
commit_all() {
  ( cd "$REPO" && git add -A && git commit -q -m "fixture" )
}

scan() {
  bash "$REPO_ROOT/bin/iac-drift-scan.sh" --target "$REPO" "$@"
}

# --- unpinned-refs -----------------------------------------------------------

@test "unpinned-refs: terraform module ?ref=main flagged" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" {
  source = "git::https://github.com/org/mod.git?ref=main"
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files main.tf)
  echo "$out" | jq -e '.findings[] | select(.kind == "unpinned-ref" and .current == "?ref=main" and .severity == "high")'
}

@test "unpinned-refs: tag-pinned ?ref=v1.2.0 NOT flagged" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" {
  source = "git::https://github.com/org/mod.git?ref=v1.2.0"
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files main.tf)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "unpinned-refs: SHA-pinned ?ref=<40hex> NOT flagged" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" {
  source = "git::https://github.com/org/mod.git?ref=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files main.tf)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "unpinned-refs: provider block without version flagged" {
  cat > "$REPO/providers.tf" <<'EOF'
provider "aws" {
  region = "us-east-1"
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files providers.tf)
  echo "$out" | jq -e '.findings[] | select(.kind == "unpinned-ref" and (.message | contains("provider")) and (.message | contains("no version")))'
}

@test "unpinned-refs: provider block WITH version NOT flagged" {
  cat > "$REPO/providers.tf" <<'EOF'
provider "aws" {
  region  = "us-east-1"
  version = "~> 5.0"
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files providers.tf)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "unpinned-refs: Helm dependency without version flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
dependencies:
  - name: redis
    repository: https://charts.example.com
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files chart/Chart.yaml)
  echo "$out" | jq -e '.findings[] | select(.kind == "unpinned-ref" and (.message | contains("redis")) and (.message | contains("no pinned version")))'
}

@test "unpinned-refs: Helm dependency with exact version NOT flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
dependencies:
  - name: redis
    version: 17.3.2
    repository: https://charts.example.com
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files chart/Chart.yaml)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "unpinned-refs: Helm dependency with version range (^) flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
dependencies:
  - name: redis
    version: ^17.0.0
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files chart/Chart.yaml)
  echo "$out" | jq -e '.findings[] | select(.kind == "unpinned-ref" and (.message | contains("moving version range")))'
}

@test "unpinned-refs: CDK package.json dep pinned to latest flagged" {
  cat > "$REPO/package.json" <<'EOF'
{
  "dependencies": {
    "aws-cdk-lib": "latest",
    "constructs": "^10.0.0"
  }
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files package.json)
  echo "$out" | jq -e '.findings[] | select(.kind == "unpinned-ref" and (.current | contains("latest")))'
}

@test "unpinned-refs: plain (non-CDK/Pulumi) package.json NOT flagged" {
  cat > "$REPO/package.json" <<'EOF'
{
  "dependencies": {
    "react": "*",
    "lodash": "latest"
  }
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files package.json)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "unpinned-refs: Pulumi requirements.txt unpinned flagged" {
  cat > "$REPO/requirements.txt" <<'EOF'
pulumi>=3.0.0
pulumi-aws
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files requirements.txt)
  echo "$out" | jq -e '.findings[] | select(.kind == "unpinned-ref" and (.message | contains("Pulumi")))'
}

@test "unpinned-refs: '# drift-ignore' suppresses module ref" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" {
  source = "git::https://github.com/org/mod.git?ref=main" # drift-ignore
}
EOF
  commit_all
  out=$(scan --detectors unpinned-refs --files main.tf)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$count" -eq 0 ]
}

# --- missing-lockfile --------------------------------------------------------

@test "missing-lockfile: terraform dir without .terraform.lock.hcl flagged once" {
  cat > "$REPO/main.tf" <<'EOF'
resource "null_resource" "x" {}
EOF
  cat > "$REPO/variables.tf" <<'EOF'
variable "y" { default = 1 }
EOF
  commit_all
  out=$(scan --detectors missing-lockfile)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "missing-lockfile")] | length')
  [ "$count" -eq 1 ]
}

@test "missing-lockfile: terraform dir WITH .terraform.lock.hcl NOT flagged" {
  cat > "$REPO/main.tf" <<'EOF'
resource "null_resource" "x" {}
EOF
  : > "$REPO/.terraform.lock.hcl"
  commit_all
  out=$(scan --detectors missing-lockfile)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "missing-lockfile")] | length')
  [ "$count" -eq 0 ]
}

@test "missing-lockfile: Helm chart with deps but no Chart.lock flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
dependencies:
  - name: redis
    version: 17.3.2
EOF
  commit_all
  out=$(scan --detectors missing-lockfile --files chart/Chart.yaml)
  echo "$out" | jq -e '.findings[] | select(.kind == "missing-lockfile" and (.message | contains("Chart.lock")))'
}

@test "missing-lockfile: Helm chart WITHOUT deps NOT flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
EOF
  commit_all
  out=$(scan --detectors missing-lockfile --files chart/Chart.yaml)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "missing-lockfile")] | length')
  [ "$count" -eq 0 ]
}

# --- secrets-in-vars (SECURITY-CRITICAL) -------------------------------------

@test "secrets-in-vars: committed AWS key in tfvars flagged CRITICAL and redacted" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files prod.tfvars)
  echo "$out" | jq -e '.findings[] | select(.kind == "secret-in-vars" and .severity == "critical")'
  # The raw secret must NOT appear verbatim in the output (redaction).
  echo "$out" | jq -e 'all(.findings[]; (.current // "") | contains("AKIAIOSFODNN7EXAMPLE") | not)'
}

@test "secrets-in-vars: committed GitHub ghr_ refresh token flagged via known shape" {
  # On a NON-secret-named key (ci_note), so only the GitHub-token shape regex
  # can catch it — locks the fix for the regex that previously omitted 'r'.
  cat > "$REPO/prod.tfvars" <<'EOF'
ci_note = "ghr_1234567890abcdefghijklmnopqrstuvwxyz12"
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files prod.tfvars)
  echo "$out" | jq -e '.findings[] | select(.kind == "secret-in-vars" and .severity == "critical" and (.message | test("GitHub")))'
}

@test "secrets-in-vars: CRITICAL — gitignored secret file NOT flagged" {
  cat > "$REPO/secret.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  echo "secret.tfvars" > "$REPO/.gitignore"
  commit_all
  # secret.tfvars is gitignored (never tracked) — the committed-only gate
  # must refuse to flag it even though the value matches a known shape.
  out=$(scan --detectors secrets-in-vars --files secret.tfvars)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  [ "$count" -eq 0 ]
}

@test "secrets-in-vars: untracked (uncommitted) secret file NOT flagged" {
  cat > "$REPO/scratch.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  # NOT committed — stays untracked. Committed-only gate must skip it.
  out=$(scan --detectors secrets-in-vars --files scratch.tfvars)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  [ "$count" -eq 0 ]
}

@test "secrets-in-vars: placeholder / var-ref values NOT flagged" {
  cat > "$REPO/example.tfvars" <<'EOF'
password = "changeme"
api_key  = "${var.api_key}"
token    = "your-token-here"
secret   = ""
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files example.tfvars)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  [ "$count" -eq 0 ]
}

@test "secrets-in-vars: high-entropy value on secret-named key flagged" {
  cat > "$REPO/creds.tfvars" <<'EOF'
db_password = "aB3xK9mQ7zR2wL5nP8vT1cD4"
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files creds.tfvars)
  echo "$out" | jq -e '.findings[] | select(.kind == "secret-in-vars" and (.message | contains("secret-named key")))'
}

@test "secrets-in-vars: high-entropy value on a NON-secret key NOT flagged" {
  cat > "$REPO/vars.tfvars" <<'EOF'
ami_id = "ami-0aB3xK9mQ7zR2wL5nP8vT1cD4xyz"
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files vars.tfvars)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  [ "$count" -eq 0 ]
}

@test "secrets-in-vars: PEM private key block flagged" {
  cat > "$REPO/key.tfvars" <<'EOF'
private_key = "-----BEGIN RSA PRIVATE KEY-----"
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files key.tfvars)
  echo "$out" | jq -e '.findings[] | select(.kind == "secret-in-vars" and (.message | contains("PEM")))'
}

@test "secrets-in-vars: allowlisted value NOT flagged" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  mkdir -p "$REPO/.nyann"
  echo "AKIAIOSFODNN7EXAMPLE" > "$REPO/.nyann/secret-allowlist"
  commit_all
  out=$(scan --detectors secrets-in-vars --files prod.tfvars)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  [ "$count" -eq 0 ]
}

@test "secrets-in-vars: '# drift-ignore' on the line suppresses the secret" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE" # drift-ignore
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files prod.tfvars)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  [ "$count" -eq 0 ]
}

@test "secrets-in-vars: Ansible group_vars committed secret flagged" {
  mkdir -p "$REPO/group_vars"
  cat > "$REPO/group_vars/all.yml" <<'EOF'
db_password: "aB3xK9mQ7zR2wL5nP8vT1cD4"
EOF
  commit_all
  out=$(scan --detectors secrets-in-vars --files group_vars/all.yml)
  echo "$out" | jq -e '.findings[] | select(.kind == "secret-in-vars")'
}

# --- version-lag -------------------------------------------------------------

@test "version-lag: Helm appVersion behind latest tag flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
appVersion: "1.0.0"
EOF
  ( cd "$REPO" && git add -A && git commit -q -m chart && git tag v1.2.0 )
  out=$(scan --detectors version-lag --files chart/Chart.yaml)
  echo "$out" | jq -e '.findings[] | select(.kind == "version-lag" and .current == "1.0.0")'
}

@test "version-lag: Helm appVersion at latest tag NOT flagged" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
appVersion: "1.2.0"
EOF
  ( cd "$REPO" && git add -A && git commit -q -m chart && git tag v1.2.0 )
  out=$(scan --detectors version-lag --files chart/Chart.yaml)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-lag")] | length')
  [ "$count" -eq 0 ]
}

@test "version-lag: no git tags → silent (nothing to compare)" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
appVersion: "0.0.1"
EOF
  commit_all
  out=$(scan --detectors version-lag --files chart/Chart.yaml)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-lag")] | length')
  [ "$count" -eq 0 ]
}

# BUG 9 lock: version-lag must flag a genuine appVersion lag in a repo that
# ALSO carries a namespaced per-unit tag (the I10 per-unit Helm release flow,
# e.g. `umbrella-2.1.0`). `git describe --abbrev=0` would surface that tag,
# which strips to a non-numeric base and masks the lag. Tag resolution must
# prefer the repo-wide SemVer tag v3.0.0 over the namespaced one.
@test "version-lag: genuine lag flagged despite a namespaced per-unit chart tag" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
appVersion: "2.0.0"
EOF
  # Order matters: create the repo-wide SemVer tag FIRST, then the namespaced
  # per-unit tag on a later commit so `git describe --abbrev=0` would pick the
  # namespaced one (most-recent) — exactly the masking scenario.
  ( cd "$REPO" \
      && git add -A && git commit -q -m chart \
      && git tag v3.0.0 \
      && git commit -q --allow-empty -m "chart release" \
      && git tag umbrella-2.1.0 )
  out=$(scan --detectors version-lag --files chart/Chart.yaml)
  # appVersion 2.0.0 lags repo-wide tag v3.0.0 → flagged, expected 3.0.0
  # (NOT umbrella-2.1.0, which would otherwise mask via a 0.0.0 base).
  echo "$out" | jq -e '.findings[] | select(.kind == "version-lag" and .current == "2.0.0" and .expected == "3.0.0")'
}

# BUG 9 lock (negative): a repo whose ONLY tag is namespaced per-unit must NOT
# spuriously flag — there is no repo-wide release line to lag behind, and the
# namespaced tag must never be parsed as a 0.0.0 comparison base.
@test "version-lag: namespaced-only tag → no repo-wide base → silent" {
  mkdir -p "$REPO/chart"
  cat > "$REPO/chart/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.1.0
appVersion: "2.0.0"
EOF
  ( cd "$REPO" && git add -A && git commit -q -m chart && git tag umbrella-2.1.0 )
  out=$(scan --detectors version-lag --files chart/Chart.yaml)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-lag")] | length')
  [ "$count" -eq 0 ]
}

# BUG 8 lock (SECURITY): --files with a `../`-traversal entry points OUTSIDE
# the repo. The per-detector `[[ -f "$target/$f" ]]` check is satisfied by the
# escaping path, so without a containment guard the external file's content
# leaks into the report. The traversal entry MUST be skipped: absent from
# scanned_files[] and contributing zero findings.
@test "traversal: --files ../escape.tf outside repo is NOT scanned or reported" {
  # Place an external file OUTSIDE the repo (in $TMP, the repo's parent) that
  # WOULD trip unpinned-refs if it were scanned.
  cat > "$TMP/escape.tf" <<'EOF'
module "leak" {
  source = "git::https://github.com/org/mod.git?ref=main"
}
EOF
  cat > "$REPO/main.tf" <<'EOF'
module "ok" { source = "git::https://github.com/org/mod.git?ref=v1.0.0" }
EOF
  commit_all
  # Capture stdout only — the skip emits a warn to stderr (which `run` would
  # fold into $output and break the JSON parse). Assert exit 0 separately.
  run scan --detectors unpinned-refs --files ../escape.tf,main.tf
  [ "$status" -eq 0 ]
  out=$(scan --detectors unpinned-refs --files ../escape.tf,main.tf 2>/dev/null)
  # The traversal entry must NOT appear in the scanned set.
  echo "$out" | jq -e 'all(.scanned_files[]; . != "../escape.tf")'
  # And nothing from the external file leaked into findings.
  echo "$out" | jq -e '[.findings[] | select(.kind == "unpinned-ref")] | length == 0'
}

# BUG 8 lock: same guard via the profile scanned_files[] path (not just
# --files). A `../`-prefixed profile entry must be dropped identically.
@test "traversal: profile scanned_files[] ../escape.tf is NOT scanned or reported" {
  cat > "$TMP/escape.tf" <<'EOF'
module "leak" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  cat > "$REPO/main.tf" <<'EOF'
module "ok" { source = "git::https://github.com/org/mod.git?ref=v1.0.0" }
EOF
  commit_all
  prof="$TMP/p.json"
  jq -n '{iac:{drift_check:{scanned_files:["../escape.tf","main.tf"]}}}' > "$prof"
  run scan --detectors unpinned-refs --profile "$prof"
  [ "$status" -eq 0 ]
  out=$(scan --detectors unpinned-refs --profile "$prof" 2>/dev/null)
  echo "$out" | jq -e 'all(.scanned_files[]; . != "../escape.tf")'
  echo "$out" | jq -e '[.findings[] | select(.kind == "unpinned-ref")] | length == 0'
}

# --- profile gating ----------------------------------------------------------

@test "profile: master enabled=false short-circuits to empty report" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  commit_all
  prof="$TMP/p.json"
  jq -n '{iac:{drift_check:{enabled:false}}}' > "$prof"
  out=$(scan --profile "$prof")
  echo "$out" | jq -e '.summary.total == 0'
  echo "$out" | jq -e '.findings == []'
}

@test "profile: per-detector disabled is silent (others still run)" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  prof="$TMP/p.json"
  # Disable the secrets detector; unpinned-refs still fires.
  jq -n '{iac:{drift_check:{enabled:true, secrets_in_vars:false}}}' > "$prof"
  out=$(scan --profile "$prof")
  sec=$(echo "$out" | jq '[.findings[] | select(.kind == "secret-in-vars")] | length')
  unp=$(echo "$out" | jq '[.findings[] | select(.kind == "unpinned-ref")] | length')
  [ "$sec" -eq 0 ]
  [ "$unp" -ge 1 ]
}

# --- graceful degradation ----------------------------------------------------

@test "non-IaC repo: graceful noop, valid empty report, exit 0" {
  echo "# readme" > "$REPO/README.md"
  echo "console.log(1)" > "$REPO/index.js"
  commit_all
  run scan
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.summary.total == 0'
  echo "$output" | jq -e '.findings == []'
}

@test "empty repo: --files listing only nonexistent paths still emits valid JSON" {
  run scan --files nope.tf,gone.tfvars
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings == []'
  echo "$output" | jq -e '.summary.total == 0'
}

# --- schema ------------------------------------------------------------------

@test "Output validates against iac-drift-report schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
provider "aws" { region = "us-east-1" }
EOF
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  scan > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/iac-drift-report.schema.json" "$TMP/r.json"
}
