#!/usr/bin/env bats
# bin/doctor.sh: clean-bootstrap → rc 0; legacy → rc 5; read-only invariant.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOCTOR="${REPO_ROOT}/bin/doctor.sh"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

# Helper: fully bootstrap a jsts-empty copy against nextjs-prototype.
bootstrap_jsts() {
  cp -r "${REPO_ROOT}/tests/fixtures/jsts-empty/." "${TMP}/"
  ( cd "$TMP" && git init -q -b main )
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$TMP" > "$TMP/.stack.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$TMP/.docplan.json"
  # Plan must declare any file bootstrap is expected to materialise —
  # preview-before-mutate means bootstrap refuses to write files not in
  # writes[]. This covers .editorconfig, CLAUDE.md, and
  # the scaffolded docs/ + memory/ entries.
  cat > "$TMP/.plan.json" <<'JSON'
{"writes":[
  {"path":".editorconfig","action":"create","bytes":0},
  {"path":"CLAUDE.md","action":"create","bytes":0},
  {"path":"docs/README.md","action":"create","bytes":0},
  {"path":"memory/README.md","action":"create","bytes":0},
  {"path":".github/workflows/ci.yml","action":"create","bytes":0},
  {"path":".github/PULL_REQUEST_TEMPLATE.md","action":"create","bytes":0}
],"commands":[],"remote":[]}
JSON
  local sha
  sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/.plan.json" --emit-sha256 2>/dev/null)
  bash "${REPO_ROOT}/bin/bootstrap.sh" \
    --target "$TMP" \
    --plan "$TMP/.plan.json" \
    --plan-sha256 "$sha" \
    --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" \
    --doc-plan "$TMP/.docplan.json" \
    --stack "$TMP/.stack.json" \
    --project-name bats-doctor > /dev/null 2>&1
}

@test "clean bootstrapped repo → doctor rc 0 (all ✓)" {
  bootstrap_jsts
  run bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '✓ CLAUDE.md'
  echo "$output" | grep -q '✓ 0 orphans'
}

@test "legacy fixture → doctor rc 5 with ✗ and ⚠ markers" {
  cp -r "${REPO_ROOT}/tests/fixtures/legacy-with-drift/." "${TMP}/"
  ( cd "$TMP" && ./seed.sh >/dev/null 2>&1 )
  run bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype
  [ "$status" -eq 5 ]
  echo "$output" | grep -q '✗'
  echo "$output" | grep -q '⚠'
}

@test "doctor without --persist is strictly read-only (no writes anywhere)" {
  bootstrap_jsts
  before=$(find "$TMP" -type f -not -path '*/.git/*' -exec shasum {} \; | sort | shasum | awk '{print $1}')
  bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype > /dev/null 2>&1 || true
  after=$(find "$TMP" -type f -not -path '*/.git/*' -exec shasum {} \; | sort | shasum | awk '{print $1}')
  [ "$before" = "$after" ]
  # And specifically: memory/health.json must not have been created.
  [ ! -f "$TMP/memory/health.json" ]
}

@test "doctor --persist writes memory/health.json (opt-in trend tracking)" {
  bootstrap_jsts
  bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --persist > /dev/null 2>&1 || true
  [ -f "$TMP/memory/health.json" ]
  # File should be valid JSON with a scores array containing at least 1 entry.
  count=$(jq '.scores | length' "$TMP/memory/health.json")
  [ "$count" -ge 1 ]
}

@test "doctor runs in under 15s on a small fixture" {
  bootstrap_jsts
  start=$(date +%s)
  bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype > /dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 15 ]
}

@test "doctor --json returns valid DriftReport JSON" {
  bootstrap_jsts
  out=$(bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --json)
  echo "$out" | jq -e 'has("missing") and has("misconfigured") and has("non_compliant_history") and has("documentation") and has("summary")' >/dev/null
}

# ---- gh-protection-audit integration --------------------------------------
# Doctor probes bin/gh-integration.sh --check and folds the result into
# both the JSON output (under .protection_audit) and the exit code
# (critical → 5, warn → 4 if not already higher). When gh is missing
# the audit emits a ProtectionAudit-shaped skip so doctor still sees
# a well-formed object.

# A mock gh that returns critical drift on the audit's main branch
# (no protection on main; tag pattern matches but no rules).
make_mock_gh_critical_protection_drift() {
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
        */vulnerability-alerts) exit 0 ;;
        */code-scanning/default-setup) echo '{"state":"configured"}'; exit 0 ;;
        */repos/nyann/fake) echo '{"id":1,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "doctor --json includes protection_audit field" {
  bootstrap_jsts
  ( cd "$TMP" && git remote add origin git@github.com:nyann/fake.git )
  make_mock_gh_critical_protection_drift
  # Doctor exits non-zero when protection drift is critical; the test
  # only cares about the JSON shape, so swallow the exit code.
  out=$(bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --json --gh "$TMP/mock/gh" 2>/dev/null || true)
  # protection_audit field present and well-formed.
  echo "$out" | jq -e 'has("protection_audit")' >/dev/null
  echo "$out" | jq -e '.protection_audit.branches | length >= 1' >/dev/null
  echo "$out" | jq -e '.protection_audit.summary.critical >= 1' >/dev/null
}

@test "doctor (text mode) renders GITHUB PROTECTION section when drift exists" {
  bootstrap_jsts
  ( cd "$TMP" && git remote add origin git@github.com:nyann/fake.git )
  make_mock_gh_critical_protection_drift
  out=$(bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --gh "$TMP/mock/gh" 2>/dev/null || true)
  echo "$out" | grep -Fq "GITHUB PROTECTION:"
  echo "$out" | grep -Fq "✗ branches/main"
}

@test "doctor exit code reflects protection critical drift" {
  bootstrap_jsts
  ( cd "$TMP" && git remote add origin git@github.com:nyann/fake.git )
  make_mock_gh_critical_protection_drift
  run bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --gh "$TMP/mock/gh"
  # Critical drift in protection audit MUST bump exit code to 5
  # regardless of whether retrofit found anything.
  [ "$status" -eq 5 ]
}

# ---- stale-branches probe integration --------------------------------------
# Doctor folds bin/check-stale-branches.sh into both JSON output (under
# .stale_branches) and text-mode display. Stale signals are
# informational — don't change exit code, but surface so users can run
# /nyann:cleanup-branches.

@test "doctor --json includes stale_branches field" {
  bootstrap_jsts
  # Create a merged branch BEFORE bootstrap installs block-main, OR
  # use --no-verify to bypass the hook on main. Going with --no-verify
  # because bootstrap_jsts already ran and we need the post-bootstrap
  # state for the doctor tests below.
  ( cd "$TMP"
    git checkout -q -b feat/done
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: done"
    git checkout -q main
    git -c user.email=t@t -c user.name=t merge --no-verify -q feat/done --no-ff -m "merge"
  )
  out=$(bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  echo "$out" | jq -e 'has("stale_branches")' >/dev/null
  echo "$out" | jq -e '.stale_branches.summary.merged_count >= 1' >/dev/null
  # feat/done should be in the merged set (we just merged it).
  echo "$out" | jq -e '[.stale_branches.merged_into_base[].name] | index("feat/done") != null' >/dev/null
}

@test "doctor (text mode) renders LOCAL BRANCHES section when something is stale or merged" {
  bootstrap_jsts
  ( cd "$TMP"
    git checkout -q -b feat/done
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: done"
    git checkout -q main
    git -c user.email=t@t -c user.name=t merge --no-verify -q feat/done --no-ff -m "merge"
  )
  out=$(bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --gh "$TMP/no-such-gh" 2>/dev/null || true)
  echo "$out" | grep -Fq "LOCAL BRANCHES:"
  echo "$out" | grep -Fq "/nyann:cleanup-branches"
}

@test "doctor with --gh pointing at a nonexistent path → audit soft-skips" {
  bootstrap_jsts
  # Point doctor at a path that doesn't exist. gh-integration's
  # `command -v "$gh_bin"` returns empty for a non-executable absolute
  # path, so the audit skips with `gh-not-installed` and emits a
  # ProtectionAudit-shaped skip JSON. Doctor must still exit cleanly
  # (no critical drift contributed) and the JSON output must include
  # the protection_audit field with all sections skipped.
  out=$(bash "$DOCTOR" --target "$TMP" --profile nextjs-prototype --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  echo "$out" | jq -e 'has("protection_audit")' >/dev/null
  echo "$out" | jq -e '.protection_audit.summary.skipped_sections | length == 6' >/dev/null
}
