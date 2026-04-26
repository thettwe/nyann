#!/usr/bin/env bats
# bin/preview.sh + bin/bootstrap.sh — preview→execute plan integrity
# binding. Prevents TOCTOU where the plan file is tampered with between
# the user's confirmation and bootstrap's read.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  TMP=$(mktemp -d -t nyann-sha.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  PROFILE="${REPO_ROOT}/profiles/typescript-library.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$PROFILE" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"

  PLAN="$TMP/plan.json"
  cat > "$PLAN" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
}

teardown() { rm -rf "$TMP"; }

# ---- preview.sh emits the SHA -----------------------------------------------

@test "preview renders and emits Plan SHA-256 on stderr" {
  run bash "$PREVIEW" --plan "$PLAN"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'Plan SHA-256: [a-f0-9]{64}$'
}

@test "--emit-sha256 prints only the hex on stdout" {
  # Capture stdout separately from stderr (bats $output merges them).
  sha=$(bash "$PREVIEW" --plan "$PLAN" --emit-sha256 2>/dev/null)
  [ "${#sha}" -eq 64 ]
  [[ "$sha" =~ ^[a-f0-9]{64}$ ]]
}

@test "whitespace-only changes to plan produce the same canonical SHA" {
  sha_compact=$(bash "$PREVIEW" --plan "$PLAN" --emit-sha256)
  # Rewrite the plan with reordered keys + pretty print.
  jq '. | {remote, commands, writes}' "$PLAN" > "$PLAN.pretty"
  sha_pretty=$(bash "$PREVIEW" --plan "$PLAN.pretty" --emit-sha256)
  [ "$sha_compact" = "$sha_pretty" ]
}

# ---- bootstrap verifies the SHA --------------------------------------------

@test "bootstrap --plan-sha256 with matching hex proceeds normally" {
  sha=$(bash "$PREVIEW" --plan "$PLAN" --emit-sha256)
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$PLAN" \
    --plan-sha256 "$sha" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
}

@test "bootstrap --plan-sha256 with wrong hex dies with a clear message" {
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$PLAN" \
    --plan-sha256 "$(printf '%064d' 0)" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plan integrity check failed"* ]]
}

@test "plan tampered between preview and bootstrap is rejected" {
  sha=$(bash "$PREVIEW" --plan "$PLAN" --emit-sha256)
  # Simulate an attacker rewriting the plan file after preview.
  cat > "$PLAN" <<'JSON'
{"writes":[{"path":"../escape/evil","action":"delete","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$PLAN" \
    --plan-sha256 "$sha" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plan integrity check failed"* ]]
  # Path-traversal guards in bootstrap.sh would also block the new
  # delete, so this test verifies the integrity check fires first
  # with the clearer error.
}

@test "bootstrap refuses to run without --plan-sha256" {
  # CLAUDE.md spells out preview-then-execute integrity binding as a
  # non-negotiable for any orchestrator that hands bootstrap an
  # ActionPlan. The flag is required; if a caller forgets it, the
  # integrity binding silently bypasses, so we refuse at arg-parse.
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$PLAN" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--plan-sha256 is required"* ]]
  # Pointer to the recovery: the error message must name the helper
  # the caller should invoke, otherwise the user is stuck.
  [[ "$output" == *"preview.sh"* ]]
  [[ "$output" == *"--emit-sha256"* ]]
}

# ---- preview.sh edge cases ---------------------------------------------------

@test "preview --decision no exits 1 with no stdout" {
  out=$(bash "$PREVIEW" --plan "$PLAN" --decision no 2>/dev/null || true)
  run bash "$PREVIEW" --plan "$PLAN" --decision no
  [ "$status" -eq 1 ]
  [ -z "$out" ]
}

@test "preview --decision invalid dies with error" {
  run bash "$PREVIEW" --plan "$PLAN" --decision maybe
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --decision"* ]]
}

@test "preview rejects malformed plan (missing required keys)" {
  bad_plan="$TMP/bad.json"
  echo '{"writes":[]}' > "$bad_plan"
  run bash "$PREVIEW" --plan "$bad_plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ActionPlan"* ]]
}

@test "preview --skip removes matching write entries from output" {
  multi_plan="$TMP/multi.json"
  cat > "$multi_plan" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0},{"path":".gitignore","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  out=$(bash "$PREVIEW" --plan "$multi_plan" --skip ".gitignore" 2>/dev/null)
  [ "$(echo "$out" | jq '.writes | length')" -eq 1 ]
  [ "$(echo "$out" | jq -r '.writes[0].path')" = "CLAUDE.md" ]
}

@test "preview without --plan dies" {
  run bash "$PREVIEW"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--plan is required"* ]]
}

@test "malformed --plan-sha256 (non-hex / wrong length) is rejected" {
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$PLAN" \
    --plan-sha256 "not-hex" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"64 hex characters"* ]]

  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$PLAN" \
    --plan-sha256 "abc123" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
}
