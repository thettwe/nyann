#!/usr/bin/env bats
# bin/bootstrap.sh — scaffold-docs and gen-claudemd are only invoked
# when the ActionPlan declares the corresponding writes. Same
# preview-before-mutate invariant that gates .editorconfig (see
# test-bootstrap-editorconfig.bats).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  TMP=$(mktemp -d -t nyann-prevgate.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  PROFILE="${REPO_ROOT}/profiles/typescript-library.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$PROFILE" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
}

teardown() { rm -rf "$TMP"; }

# Compute the canonical SHA-256 of a plan file the way bootstrap expects.
plan_sha() { bash "$PREVIEW" --plan "$1" --emit-sha256 2>/dev/null; }

# ---- CLAUDE.md gating ------------------------------------------------------

@test "CLAUDE.md NOT written when absent from plan writes[]" {
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/CLAUDE.md" ]
  echo "$output" | grep -Fq "CLAUDE.md is not in the ActionPlan"
}

@test "CLAUDE.md IS written when declared in plan writes[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -f "$REPO/CLAUDE.md" ]
  grep -Fq '<!-- nyann:start -->' "$REPO/CLAUDE.md"
}

@test "profile claude_md_mode=off suppresses gen-claudemd even when plan declares it" {
  # Copy the profile and tweak claude_md_mode → off.
  profile_off="$TMP/profile-off.json"
  jq '.documentation.claude_md_mode = "off"' "$PROFILE" > "$profile_off"

  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$profile_off" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/CLAUDE.md" ]
  echo "$output" | grep -Fq "claude_md_mode=off"
}

# ---- docs scaffolding gating -----------------------------------------------

@test "scaffold-docs skipped when plan declares no docs/ or memory/ entries" {
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -d "$REPO/docs" ]
  [ ! -d "$REPO/memory" ]
  echo "$output" | grep -Fq "scaffold-docs"
  echo "$output" | grep -Fq "ActionPlan"
}

@test "scaffold-docs runs when plan includes docs/ entries" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[
  {"path":"docs/architecture.md","action":"create","bytes":0},
  {"path":"memory/README.md","action":"create","bytes":0}
],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -d "$REPO/docs" ]
  [ -f "$REPO/docs/README.md" ]  || [ -f "$REPO/docs/architecture.md" ]
}

# ---- remote[] gate ---------------------------------------------------------
# preview.sh renders ActionPlan.remote[] but bootstrap has no dispatcher
# yet. Silently dropping the entries would lie to preview-before-mutate
# (the user saw branch-protection rules in preview and now they aren't
# being applied). Bootstrap must refuse the plan instead.

@test "bootstrap refuses a plan with non-empty remote[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[
  {"type":"branch_protection","branch":"main","rules":{"require_pr":true}}
]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "remote[]"
  echo "$output" | grep -Fq "no remote dispatcher"
  # Pointer to the sanctioned tool for the supported case.
  echo "$output" | grep -Fq "gh-integration.sh"
}

@test "bootstrap accepts a plan with empty remote[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
}
