#!/usr/bin/env bats
# bin/iac-plan.sh + bin/iac-plan/<tool>.sh adapters (I9 — plan side).
#
# Strategy: a FAKE tool CLI (terraform / tofu / pulumi / cdk) is placed on PATH
# emitting canned machine-readable plan output, so we exercise normalization +
# the destructive flag WITHOUT any real cloud access. NYANN_IAC_TOOL pins the
# tool so detection doesn't have to be re-derived per case (detection itself is
# covered by test-detect-*.bats). We assert:
#   - each structured tool's plan is normalized into {add,change,destroy},
#   - the destructive flag (destroy>0 for structured; always-true for advisory),
#   - destructive_known is true for structured, false for advisory,
#   - missing-CLI soft-skips (status:"skipped", exit 0),
#   - --unit scoping + path-traversal refusal,
#   - plan is READ-ONLY (never runs an apply subcommand),
#   - the IacPlan validates against its schema.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-iac-plan.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  STUB="$TMP/stub-bin"
  mkdir -p "$REPO" "$STUB"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
  # Isolate from any real cloud CLI on the developer's PATH: prepend the stub
  # dir, then keep ONLY the dirs holding the support tools the scripts need
  # (jq, git, uvx) plus base system dirs — so a real terraform/pulumi/cdk on
  # the dev's PATH can never leak into the missing-CLI soft-skip cases.
  export CI=true
  local support=""
  for t in jq git uvx; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$p" ]] && support="$support:$(dirname "$p")"
  done
  export PATH="$STUB${support}:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() { rm -rf "$TMP"; }

plan() { NYANN_IAC_TOOL="$1" bash "$REPO_ROOT/bin/iac-plan.sh" --target "$REPO" "${@:2}"; }

# Record every invocation of the fake CLI so we can prove plan never applies.
_calllog() { echo "$TMP/calls.log"; }

# --- terraform stub: add+destroy plan ---------------------------------------

_stub_terraform() {
  # $1 = the canned `show -json`. Writes a fake plan binary; logs every call.
  local showjson="$1"
  cat > "$STUB/terraform" <<STUB
#!/usr/bin/env bash
echo "terraform \$*" >> "$TMP/calls.log"
prev=""
case "\$1" in
  plan)
    out=""
    for a in "\$@"; do
      case "\$prev" in -out) out="\$a";; esac
      case "\$a" in -out=*) out="\${a#-out=}";; esac
      prev="\$a"
    done
    [ -n "\$out" ] && : > "\$out"
    exit 0 ;;
  show)
    cat <<'JSON'
$showjson
JSON
    exit 0 ;;
  apply) echo "APPLIED" ; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB/terraform"
}

@test "terraform: create+delete plan normalized to add=1 destroy=1, destructive, structured" {
  _stub_terraform '{"resource_changes":[{"change":{"actions":["create"]}},{"change":{"actions":["delete"]}}]}'
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out=$(plan terraform)
  echo "$out" | jq -e '.status == "planned"'
  echo "$out" | jq -e '.tool == "terraform"'
  echo "$out" | jq -e '.summary.add == 1 and .summary.change == 0 and .summary.destroy == 1'
  echo "$out" | jq -e '.destructive == true'
  echo "$out" | jq -e '.destructive_known == true'
}

@test "terraform: update-only plan is NON-destructive" {
  _stub_terraform '{"resource_changes":[{"change":{"actions":["update"]}}]}'
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out=$(plan terraform)
  echo "$out" | jq -e '.summary.add == 0 and .summary.change == 1 and .summary.destroy == 0'
  echo "$out" | jq -e '.destructive == false'
}

@test "terraform: replacement (delete,create) counts both destroy and add, destructive" {
  _stub_terraform '{"resource_changes":[{"change":{"actions":["delete","create"]}}]}'
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out=$(plan terraform)
  echo "$out" | jq -e '.summary.add == 1 and .summary.destroy == 1'
  echo "$out" | jq -e '.destructive == true'
}

@test "terraform: no-op plan is empty + non-destructive" {
  _stub_terraform '{"resource_changes":[{"change":{"actions":["no-op"]}}]}'
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out=$(plan terraform)
  echo "$out" | jq -e '.summary.add == 0 and .summary.change == 0 and .summary.destroy == 0'
  echo "$out" | jq -e '.destructive == false'
}

@test "terraform: plan is READ-ONLY — never invokes apply" {
  _stub_terraform '{"resource_changes":[{"change":{"actions":["create"]}}]}'
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  plan terraform >/dev/null
  run grep -c 'terraform apply' "$TMP/calls.log"
  [ "$output" = "0" ]
  grep -q 'terraform plan' "$TMP/calls.log"
  grep -q 'terraform show' "$TMP/calls.log"
}

@test "opentofu: dispatches to terraform adapter with tofu CLI" {
  cat > "$STUB/tofu" <<STUB
#!/usr/bin/env bash
echo "tofu \$*" >> "$TMP/calls.log"
prev=""
case "\$1" in
  plan)
    out=""; for a in "\$@"; do case "\$prev" in -out) out="\$a";; esac; case "\$a" in -out=*) out="\${a#-out=}";; esac; prev="\$a"; done
    [ -n "\$out" ] && : > "\$out"; exit 0 ;;
  show) echo '{"resource_changes":[{"change":{"actions":["delete"]}}]}'; exit 0 ;;
esac
STUB
  chmod +x "$STUB/tofu"
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out=$(plan opentofu)
  echo "$out" | jq -e '.tool == "opentofu" and .summary.destroy == 1 and .destructive == true'
  grep -q 'tofu plan' "$TMP/calls.log"
}

# --- pulumi stub: structured preview --json ----------------------------------

@test "pulumi: preview --json changeSummary normalized, replace counts as destroy" {
  cat > "$STUB/pulumi" <<STUB
#!/usr/bin/env bash
echo "pulumi \$*" >> "$TMP/calls.log"
if [ "\$1" = "preview" ]; then
  echo '{"changeSummary":{"create":2,"update":1,"replace":1,"same":3}}'
  exit 0
fi
exit 0
STUB
  chmod +x "$STUB/pulumi"
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: infra
runtime: nodejs
EOF
  out=$(plan pulumi)
  echo "$out" | jq -e '.tool == "pulumi"'
  echo "$out" | jq -e '.summary.add == 2 and .summary.change == 1 and .summary.destroy == 1'
  echo "$out" | jq -e '.destructive == true and .destructive_known == true'
}

@test "pulumi: steps[].op fallback when no changeSummary, delete is destructive" {
  cat > "$STUB/pulumi" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "preview" ]; then
  echo '{"steps":[{"op":"create"},{"op":"delete"},{"op":"same"}]}'
  exit 0
fi
STUB
  chmod +x "$STUB/pulumi"
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: infra
runtime: python
EOF
  out=$(plan pulumi)
  echo "$out" | jq -e '.summary.add == 1 and .summary.destroy == 1 and .destructive == true'
}

# --- cdk stub: structured diff parse -----------------------------------------

@test "aws-cdk: cdk diff prefixes parsed, [-] is destructive" {
  cat > "$STUB/cdk" <<STUB
#!/usr/bin/env bash
echo "cdk \$*" >> "$TMP/calls.log"
if [ "\$1" = "diff" ]; then
  cat <<'OUT'
Resources
[+] AWS::S3::Bucket NewBucket
[~] AWS::IAM::Role ChangedRole
[-] AWS::EC2::Instance OldInstance
OUT
  exit 1   # cdk diff exits 1 when there IS a diff
fi
STUB
  chmod +x "$STUB/cdk"
  cat > "$REPO/cdk.json" <<'EOF'
{ "app": "npx ts-node bin/app.ts" }
EOF
  out=$(plan aws-cdk)
  echo "$out" | jq -e '.tool == "aws-cdk"'
  echo "$out" | jq -e '.summary.add == 1 and .summary.change == 1 and .summary.destroy == 1'
  echo "$out" | jq -e '.destructive == true and .destructive_known == true'
}

# --- advisory tool: helm template (text diff only) ---------------------------

@test "helm: advisory text diff — counts 0, destructive_known false, destructive true (fail-safe)" {
  cat > "$STUB/helm" <<STUB
#!/usr/bin/env bash
case "\$1" in
  plugin) echo "no plugins"; exit 0 ;;          # no helm-diff plugin
  template) echo "rendered: kind: Deployment"; exit 0 ;;
esac
STUB
  chmod +x "$STUB/helm"
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: mychart
version: 0.1.0
EOF
  out=$(plan helm)
  echo "$out" | jq -e '.status == "planned" and .tool == "helm"'
  echo "$out" | jq -e '.summary.add == 0 and .summary.change == 0 and .summary.destroy == 0'
  echo "$out" | jq -e '.destructive_known == false'
  # Advisory ⇒ conservatively destructive so the apply gate engages.
  echo "$out" | jq -e '.destructive == true'
}

# --- missing CLI soft-skip ---------------------------------------------------

@test "missing terraform CLI → soft-skip status:skipped, exit 0" {
  # No stub written → terraform absent on the isolated PATH.
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  run plan terraform
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "skipped"'
  echo "$output" | jq -e '.summary.add == 0 and .summary.destroy == 0'
}

@test "missing pulumi CLI → soft-skip exit 0" {
  cat > "$REPO/Pulumi.yaml" <<'EOF'
name: infra
runtime: go
EOF
  run plan pulumi
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "skipped"'
}

@test "no IaC tool detected → soft-skip (empty repo)" {
  run bash "$REPO_ROOT/bin/iac-plan.sh" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "skipped" and .tool == ""'
}

# --- backend/creds absent soft-skip ------------------------------------------

@test "terraform plan fails (no backend/creds) → soft-skip, never partial" {
  cat > "$STUB/terraform" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "plan" ]; then
  echo "Error: Backend initialization required, please run terraform init" >&2
  exit 1
fi
STUB
  chmod +x "$STUB/terraform"
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  run plan terraform
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "skipped"'
  echo "$output" | jq -e '.message | test("init|backend"; "i")'
}

# --- --unit scoping ----------------------------------------------------------

@test "--unit scopes the plan to a subdirectory" {
  _stub_terraform '{"resource_changes":[{"change":{"actions":["create"]}}]}'
  mkdir -p "$REPO/modules/vpc"
  echo 'resource "null_resource" "x" {}' > "$REPO/modules/vpc/main.tf"
  out=$(plan terraform --unit modules/vpc)
  echo "$out" | jq -e '.unit == "modules/vpc"'
  echo "$out" | jq -e '.status == "planned" and .summary.add == 1'
}

@test "--unit path traversal is refused" {
  _stub_terraform '{"resource_changes":[]}'
  run plan terraform --unit ../../etc
  echo "$output" | jq -e '.status == "refused"'
  echo "$output" | jq -e '.message | test("escapes")'
}

# --- BUG 7 LOCK: --unit may be a stack DESCRIPTOR FILE (CDK/Pulumi) ----------

@test "--unit pointing at a CDK stack FILE resolves to its dir (not refused)" {
  # The documented "plan a discovered stack" workflow hands iac.units[].path —
  # a FILE for CDK/Pulumi — to --unit. It must be accepted (resolve to its dir),
  # not hard-refused as "not a directory".
  cat > "$STUB/cdk" <<STUB
#!/usr/bin/env bash
echo "cdk \$*" >> "$TMP/calls.log"
if [ "\$1" = "diff" ]; then
  echo "Resources"; echo "[+] AWS::S3::Bucket NewBucket"; exit 1
fi
STUB
  chmod +x "$STUB/cdk"
  mkdir -p "$REPO/app"
  cat > "$REPO/app/cdk.json" <<'EOF'
{ "app": "npx ts-node bin/app.ts" }
EOF
  out=$(plan aws-cdk --unit app/cdk.json)
  echo "$out" | jq -e '.status == "planned"'
  echo "$out" | jq -e '.tool == "aws-cdk"'
}

# --- schema validation -------------------------------------------------------

@test "planned IacPlan validates against iac-plan schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
  _stub_terraform '{"resource_changes":[{"change":{"actions":["create"]}},{"change":{"actions":["delete"]}}]}'
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  plan terraform > "$TMP/plan.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/iac-plan.schema.json" "$TMP/plan.json"
}

@test "skipped IacPlan validates against iac-plan schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  plan terraform > "$TMP/plan.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/iac-plan.schema.json" "$TMP/plan.json"
}

# --- BUG 5 LOCK: unsupported-tool refusal stays schema-valid (tool == "") ----

@test "unsupported tool refusal emits tool:\"\" and validates against schema" {
  # An unknown tool must NOT leak its raw name into IacPlan.tool — the schema's
  # tool enum only allows the 8 known tools + "". The raw name lives in the
  # message instead, so the refused output always validates.
  run env NYANN_IAC_TOOL=foobar bash "$REPO_ROOT/bin/iac-plan.sh" --target "$REPO"
  [ "$status" -eq 1 ]   # refusal exits 1
  echo "$output" | jq -e '.status == "refused"'
  echo "$output" | jq -e '.tool == ""'
  echo "$output" | jq -e '.message | test("foobar")'

  if command -v uvx >/dev/null 2>&1 || command -v check-jsonschema >/dev/null 2>&1; then
    if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
    echo "$output" > "$TMP/refused.json"
    "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/iac-plan.schema.json" "$TMP/refused.json"
  fi
}

# --- BUG 4 LOCK: helm release-name option injection -------------------------

@test "helm: a release name starting with '-' never reaches helm as a bare flag" {
  # A chart dir named like a flag (-rf / --namespace) must be rejected OR only
  # reach helm after a `--` end-of-options separator. We log helm's full argv
  # and assert the release token never appears before `--`.
  cat > "$STUB/helm" <<STUB
#!/usr/bin/env bash
echo "helm \$*" >> "$TMP/calls.log"
case "\$1" in
  plugin) echo "diff"; exit 0 ;;   # pretend helm-diff plugin IS present
  diff)   echo "rendered diff"; exit 0 ;;
  template) echo "rendered: kind: Deployment"; exit 0 ;;
esac
STUB
  chmod +x "$STUB/helm"
  mkdir -p "$REPO/-rf"
  cat > "$REPO/-rf/Chart.yaml" <<'EOF'
apiVersion: v2
name: mychart
version: 0.1.0
EOF
  run plan helm --unit -rf
  # Either the plan refused the dangerous name, or helm was invoked safely.
  if echo "$output" | jq -e '.status == "refused"' >/dev/null 2>&1; then
    : # rejected cleanly — acceptable
  else
    # If helm ran, the `-rf` release token must appear ONLY after `--`.
    if grep -q 'helm diff' "$TMP/calls.log"; then
      line="$(grep 'helm diff' "$TMP/calls.log" | tail -1)"
      # everything before the first ` -- ` must NOT contain the bare `-rf` token
      before="${line%% -- *}"
      echo "$before" | grep -vqw -- '-rf'
      # and the separator must be present
      echo "$line" | grep -q -- ' -- '
    fi
  fi
}
