#!/usr/bin/env bats
# bin/iac-apply.sh + bin/guards/iac-apply-confirmation.sh (I9 — apply side).
#
# THE highest-stakes path in nyann. Every test here pins a HARD SAFETY
# INVARIANT in code. A fake tool CLI on PATH (terraform/pulumi) emits a canned
# plan AND logs every invocation, so we can prove apply was/was NOT called.
#
# Invariants asserted:
#   - apply is NEVER the default: no --apply ⇒ status:"preview", no apply run.
#   - --dry-run wins over --apply ⇒ preview, no apply run.
#   - destroy>0 ⇒ REFUSE without --confirm-destroy, even WITH --apply.
#   - --apply --confirm-destroy on a destructive plan ⇒ applies + writes record.
#   - non-destructive plan applies with just --apply (no --confirm-destroy).
#   - the IacApplyRecord contains NO credentials and NO state/raw bytes.
#   - missing CLI ⇒ soft-skip (status:"skipped", exit 0), never partial-apply.
#   - the confirmation guard fails closed on a missing/destructive plan.
#   - the record validates against iac-apply-record schema.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-iac-apply.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  STUB="$TMP/stub-bin"
  mkdir -p "$REPO" "$STUB"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
  export CI=true
  local support="" p
  for t in jq git uvx; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$p" ]] && support="$support:$(dirname "$p")"
  done
  export PATH="$STUB${support}:/usr/bin:/bin:/usr/sbin:/sbin"
  CALLS="$TMP/calls.log"; : > "$CALLS"
}

teardown() { rm -rf "$TMP"; }

apply() { NYANN_IAC_TOOL=terraform bash "$REPO_ROOT/bin/iac-apply.sh" --target "$REPO" "$@"; }

# Stub terraform with a configurable show-json; logs every call to $CALLS.
_stub_tf() {
  local showjson="$1"
  cat > "$STUB/terraform" <<STUB
#!/usr/bin/env bash
echo "terraform \$*" >> "$TMP/calls.log"
prev=""
case "\$1" in
  plan)
    out=""; for a in "\$@"; do case "\$prev" in -out) out="\$a";; esac; case "\$a" in -out=*) out="\${a#-out=}";; esac; prev="\$a"; done
    [ -n "\$out" ] && : > "\$out"; exit 0 ;;
  show) cat <<'JSON'
$showjson
JSON
    exit 0 ;;
  apply) echo "[stub-tf] APPLYING — would mutate infra"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$STUB/terraform"
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
}

_destructive() { _stub_tf '{"resource_changes":[{"change":{"actions":["create"]}},{"change":{"actions":["delete"]}}]}'; }
_safe()        { _stub_tf '{"resource_changes":[{"change":{"actions":["create"]}}]}'; }

# Count real `terraform apply` invocations. grep -c prints 0 + exits 1 on no
# match, so normalize to a clean integer the `-eq` tests can use.
_applied_count() {
  local n
  n="$(grep -c 'terraform apply' "$CALLS" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# --- INVARIANT 1: apply is never the default --------------------------------

@test "no --apply → PREVIEW, never applies (preview-by-default)" {
  _destructive
  out="$(apply 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ]
  echo "$out" | jq -e '.status == "preview"'
  [ "$(_applied_count)" -eq 0 ]
}

@test "no --apply on a non-destructive plan still PREVIEWS" {
  _safe
  out="$(apply 2>/dev/null)"
  echo "$out" | jq -e '.status == "preview"'
  [ "$(_applied_count)" -eq 0 ]
}

# --- INVARIANT 2: --dry-run wins over --apply -------------------------------

@test "--dry-run --apply --confirm-destroy → PREVIEW, never applies" {
  _destructive
  out="$(apply --apply --confirm-destroy --dry-run 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ]
  echo "$out" | jq -e '.status == "preview"'
  [ "$(_applied_count)" -eq 0 ]
}

# --- INVARIANT 3: destroy>0 needs --confirm-destroy -------------------------

@test "--apply WITHOUT --confirm-destroy on destructive plan → REFUSE, never applies" {
  _destructive
  # Refusal exits non-zero (1); tolerate it in the capture.
  out="$(apply --apply 2>/dev/null || true)"
  echo "$out" | jq -e '.status == "refused"'
  echo "$out" | jq -e '.message | test("confirm-destroy")'
  [ "$(_applied_count)" -eq 0 ]
}

@test "destructive apply cannot be authorized by a single flag" {
  # --confirm-destroy alone (no --apply) must still PREVIEW (apply not default).
  _destructive
  out="$(apply --confirm-destroy 2>/dev/null)"
  echo "$out" | jq -e '.status == "preview"'
  [ "$(_applied_count)" -eq 0 ]
}

@test "crafted --plan (destroy>0 but destructive:false) cannot apply with a single flag" {
  # Trust-boundary lock: a stale or hand-edited plan from the save-then-apply
  # workflow that LIES (destroy:9, destructive:false) must NOT slip a destroy
  # past the gate. destructive is recomputed from summary.destroy, so --apply
  # alone is refused — never applied.
  _safe   # install the terraform stub so the apply CLI is present (GATE 3)
  cat > "$TMP/evil.json" <<'JSON'
{"schema_version":1,"status":"planned","tool":"terraform","unit":".","summary":{"add":0,"change":0,"destroy":9},"destructive":false,"destructive_known":true,"raw_path":"/tmp/x"}
JSON
  out="$(apply --plan "$TMP/evil.json" --apply 2>/dev/null || true)"  # refusal exits 1
  echo "$out" | jq -e '.status == "refused"'
  [ "$(_applied_count)" -eq 0 ]
}

@test "guard treats a destroy>0 / destructive:false plan as destructive (fail-safe)" {
  echo '{"summary":{"destroy":9},"destructive":false,"destructive_known":true}' > "$TMP/evil.json"
  out="$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" \
    --plan "$TMP/evil.json" --confirm-destroy false --confirmed false 2>/dev/null)"
  echo "$out" | jq -e '.pass == false'
}

# --- INVARIANT 4: destructive apply WITH both flags applies + records -------

@test "--apply --confirm-destroy on destructive plan → APPLIES + writes record" {
  _destructive
  # Capture stdout (JSON) only; tool/log output goes to stderr.
  out="$(apply --apply --confirm-destroy 2>/dev/null)"
  echo "$out" | jq -e '.status == "applied"'
  echo "$out" | jq -e '.exit_code == 0'
  [ "$(_applied_count)" -eq 1 ]
  rec="$(echo "$out" | jq -r '.record_path')"
  [ -f "$rec" ]
  jq -e '.gates.apply_flag == true and .gates.confirm_destroy == true and .gates.confirmation_guard == "pass"' "$rec"
  jq -e '.summary.destroy == 1 and .destructive == true' "$rec"
}

# --- INVARIANT 5: non-destructive applies with just --apply -----------------

@test "non-destructive plan applies with just --apply (no --confirm-destroy)" {
  _safe
  out="$(apply --apply 2>/dev/null)"
  echo "$out" | jq -e '.status == "applied"'
  [ "$(_applied_count)" -eq 1 ]
  rec="$(echo "$out" | jq -r '.record_path')"
  # confirm_destroy not required ⇒ recorded false, guard not-required.
  jq -e '.gates.confirm_destroy == false and .gates.confirmation_guard == "not-required"' "$rec"
}

# --- INVARIANT 6: record carries NO credentials/state -----------------------

@test "apply record contains NO credentials, secrets, or state" {
  _destructive
  # Place secret-bearing var/state files in the repo to prove they don't leak.
  cat > "$REPO/secret.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
db_password = "hunter2supersecret"
EOF
  echo '{"version":4,"resources":[{"name":"db","password":"leakedstate"}]}' > "$REPO/terraform.tfstate"
  out="$(apply --apply --confirm-destroy 2>/dev/null)"
  rec="$(echo "$out" | jq -r '.record_path')"
  [ -f "$rec" ]
  # No credential/state markers anywhere in the record.
  run grep -iE 'AKIA|hunter2|leakedstate|access_key|db_password|tfstate|BEGIN .*PRIVATE|secret_key' "$rec"
  [ "$status" -ne 0 ]
  # No absolute path leak — target is a basename.
  jq -e '.target == "repo"' "$rec"
  # Record dir holds ONLY the manifest — no copied state/var blobs.
  recdir="$(dirname "$rec")"
  run find "$recdir" -type f
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "apply record stores no raw plan/state bytes — only metadata keys" {
  _destructive
  out="$(apply --apply --confirm-destroy 2>/dev/null)"
  rec="$(echo "$out" | jq -r '.record_path')"
  # Closed key set — additionalProperties:false in schema; assert top-level keys.
  keys="$(jq -r 'keys_unsorted | join(",")' "$rec")"
  echo "$keys" | grep -qv 'state'
  jq -e 'has("summary") and has("gates") and has("apply") and (.apply | has("exit_code"))' "$rec"
  # apply block must NOT carry stdout/argv/var values.
  jq -e '.apply | (has("stdout") or has("stderr") or has("argv")) | not' "$rec"
}

# --- INVARIANT 7: missing CLI soft-skips ------------------------------------

@test "missing terraform CLI → soft-skip (status:skipped, exit 0), never partial" {
  # No terraform stub → CLI absent. Plan soft-skips, so apply soft-skips.
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  out="$(apply --apply --confirm-destroy 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ]
  echo "$out" | jq -e '.status == "skipped"'
  [ "$(_applied_count)" -eq 0 ]
  # No record written for a skip.
  # No record dir at all (skip) → no manifest. Guard the find so a missing
  # dir doesn't print an error into $output.
  found=""
  [ -d "$REPO/memory/.nyann/iac-applies" ] && found="$(find "$REPO/memory/.nyann/iac-applies" -name manifest.json)"
  [ -z "$found" ]
}

@test "apply CLI vanishes after a successful plan → soft-skip, no record" {
  # Plan succeeds (structured), then remove the CLI before apply runs.
  _destructive
  plan_json="$(NYANN_IAC_TOOL=terraform bash "$REPO_ROOT/bin/iac-plan.sh" --target "$REPO")"
  echo "$plan_json" > "$TMP/plan.json"
  rm -f "$STUB/terraform"
  out="$(apply --apply --confirm-destroy --plan "$TMP/plan.json" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ]
  echo "$out" | jq -e '.status == "skipped"'
  # No record dir at all (skip) → no manifest. Guard the find so a missing
  # dir doesn't print an error into $output.
  found=""
  [ -d "$REPO/memory/.nyann/iac-applies" ] && found="$(find "$REPO/memory/.nyann/iac-applies" -name manifest.json)"
  [ -z "$found" ]
}

# --- the confirmation guard in isolation ------------------------------------

@test "guard: destructive plan FAILS without --confirm-destroy" {
  echo '{"destructive":true,"destructive_known":true,"summary":{"add":0,"change":0,"destroy":2}}' > "$TMP/p.json"
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" --plan "$TMP/p.json" --confirm-destroy false)
  echo "$out" | jq -e '.name == "iac-apply-confirmation" and .pass == false and .severity == "critical"'
}

@test "guard: destructive plan PASSES with --confirm-destroy AND confirmation" {
  echo '{"destructive":true,"destructive_known":true,"summary":{"add":0,"change":0,"destroy":2}}' > "$TMP/p.json"
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" --plan "$TMP/p.json" --confirm-destroy true --confirmed true)
  echo "$out" | jq -e '.pass == true'
}

@test "guard: non-destructive plan is not-required (pass, skipped)" {
  echo '{"destructive":false,"destructive_known":true,"summary":{"add":1,"change":0,"destroy":0}}' > "$TMP/p.json"
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" --plan "$TMP/p.json")
  echo "$out" | jq -e '.pass == true and .skipped == true'
}

@test "guard: missing plan FAILS CLOSED" {
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" --plan "$TMP/does-not-exist.json")
  echo "$out" | jq -e '.pass == false'
}

# --- BUG 6 LOCK: empty / whitespace plan must FAIL CLOSED -------------------

@test "guard: 0-byte plan file FAILS CLOSED (not gate-not-required)" {
  # A 0-byte plan makes `jq -r 'if ... then "true" else "false"'` exit 0 with NO
  # output, which would set destructive="" and PASS the gate as not-required — a
  # fail-OPEN hole. The guard must refuse an empty plan.
  : > "$TMP/empty.json"
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" \
    --plan "$TMP/empty.json" --confirm-destroy false --confirmed false)
  echo "$out" | jq -e '.pass == false'
  # Must NOT report itself as a satisfied not-required no-op.
  echo "$out" | jq -e '(.skipped // false) == false'
}

@test "guard: whitespace-only plan file FAILS CLOSED" {
  printf '   \n\t\n' > "$TMP/ws.json"
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" \
    --plan "$TMP/ws.json" --confirm-destroy false --confirmed false)
  echo "$out" | jq -e '.pass == false'
}

@test "guard: non-object plan (bare array/scalar) FAILS CLOSED" {
  printf '[]' > "$TMP/arr.json"
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" \
    --plan "$TMP/arr.json" --confirm-destroy true --confirmed true)
  echo "$out" | jq -e '.pass == false'
}

@test "guard: advisory plan (destructive_known false) is treated destructive" {
  echo '{"destructive":true,"destructive_known":false,"summary":{"add":0,"change":0,"destroy":0}}' > "$TMP/p.json"
  # Without confirm-destroy → fail.
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" --plan "$TMP/p.json" --confirm-destroy false)
  echo "$out" | jq -e '.pass == false'
  # With confirm-destroy → pass, message notes unknown destroy count.
  out=$(bash "$REPO_ROOT/bin/guards/iac-apply-confirmation.sh" --plan "$TMP/p.json" --confirm-destroy true --confirmed true)
  echo "$out" | jq -e '.pass == true and (.message | test("unknown"))'
}

# --- schema validation -------------------------------------------------------

@test "apply record validates against iac-apply-record schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
  _destructive
  out="$(apply --apply --confirm-destroy 2>/dev/null)"
  rec="$(echo "$out" | jq -r '.record_path')"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/iac-apply-record.schema.json" "$rec"
}

@test "non-destructive apply record validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
  _safe
  out="$(apply --apply 2>/dev/null)"
  rec="$(echo "$out" | jq -r '.record_path')"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/iac-apply-record.schema.json" "$rec"
}

# --- BUG 4 LOCK: helm apply release-name option injection -------------------

@test "helm apply: a '-' release name is rejected OR only reaches helm after --" {
  # A chart dir / --unit named like a flag (-rf / --namespace) must never reach
  # `helm upgrade --install` as a bare token during the highest-stakes mutator.
  # Supply a destructive advisory plan via --plan so we drive the helm apply
  # path directly, with --unit pointing at the dangerous dir.
  cat > "$STUB/helm" <<STUB
#!/usr/bin/env bash
echo "helm \$*" >> "$TMP/calls.log"
exit 0
STUB
  chmod +x "$STUB/helm"
  mkdir -p "$REPO/-rf"
  cat > "$REPO/-rf/Chart.yaml" <<'EOF'
apiVersion: v2
name: c
version: 0.1.0
EOF
  cat > "$TMP/helmplan.json" <<'JSON'
{"schema_version":1,"status":"planned","tool":"helm","unit":"-rf","summary":{"add":0,"change":0,"destroy":0},"destructive":true,"destructive_known":false}
JSON
  run env NYANN_IAC_TOOL=helm bash "$REPO_ROOT/bin/iac-apply.sh" \
    --target "$REPO" --unit -rf --plan "$TMP/helmplan.json" --apply --confirm-destroy
  # Either apply refused/died on the dangerous name, or helm ran with `--`.
  if grep -q 'helm upgrade' "$TMP/calls.log" 2>/dev/null; then
    line="$(grep 'helm upgrade' "$TMP/calls.log" | tail -1)"
    before="${line%% -- *}"
    echo "$before" | grep -vqw -- '-rf'   # bare -rf must NOT precede the separator
    echo "$line" | grep -q -- ' -- '      # the -- separator must be present
  else
    # No helm invocation ⇒ apply rejected the name before constructing argv.
    [ "$status" -ne 0 ]
  fi
}

# --- BUG 7 LOCK: apply --unit may be a stack DESCRIPTOR FILE -----------------

@test "apply --unit pointing at a Pulumi stack FILE resolves to its dir" {
  # Mirror the plan side: iac.units[].path is a FILE for CDK/Pulumi. apply must
  # accept it (resolve to the containing dir) instead of dying on cd into a file.
  cat > "$STUB/pulumi" <<STUB
#!/usr/bin/env bash
echo "pulumi \$*" >> "$TMP/calls.log"
if [ "\$1" = "preview" ]; then echo '{"changeSummary":{"create":1,"same":0}}'; exit 0; fi
if [ "\$1" = "up" ]; then echo "[stub] pulumi up"; exit 0; fi
exit 0
STUB
  chmod +x "$STUB/pulumi"
  mkdir -p "$REPO/stacks/prod"
  cat > "$REPO/stacks/prod/Pulumi.yaml" <<'EOF'
name: infra
runtime: nodejs
EOF
  # Capture stdout (JSON) only — tool/log output streams to stderr.
  out="$(NYANN_IAC_TOOL=pulumi bash "$REPO_ROOT/bin/iac-apply.sh" \
    --target "$REPO" --unit stacks/prod/Pulumi.yaml --apply 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ]
  echo "$out" | jq -e '.status == "applied"'
  # pulumi up must have run in the stack's DIRECTORY, not been refused.
  grep -q 'pulumi up' "$TMP/calls.log"
}
