#!/usr/bin/env bats
# bin/optimize-claudemd.sh — CLAUDE.md optimization tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  OPTIMIZE="${REPO_ROOT}/bin/optimize-claudemd.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO/memory" "$REPO/docs"

  PROFILE="$TMP/profile.json"
  cat > "$PROFILE" <<'JSON'
{
  "name": "test-profile",
  "schemaVersion": 1,
  "stack": { "primary_language": "typescript" },
  "hooks": { "pre_commit": ["eslint"], "commit_msg": ["conventional-commits"], "pre_push": [] },
  "conventions": { "commit_format": "conventional-commits" },
  "documentation": { "claude_md_mode": "router", "claude_md_size_budget_kb": 3 }
}
JSON
}

teardown() { rm -rf "$TMP"; }

# Extract JSON from mixed stdout+stderr output (skip [nyann] log lines)
json_output() { echo "$output" | grep -v '^\[nyann\]'; }

make_claudemd() {
  cat > "$REPO/CLAUDE.md" <<'MD'
# Project

User content above markers.

<!-- nyann:start -->

## Build commands

- `npm test` — run tests
- `npm run lint` — run linter

## Unused section

This section has a lot of content that nobody references.
It contains detailed information about something that is
no longer relevant to the project.

## Conventions

Commit format: conventional-commits

<!-- nyann:end -->

User content below markers.
MD
}

make_usage_with_remove() {
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 20,
  "sections": {
    "Build commands": { "referenced": 30, "last_referenced": "2025-01-15T00:00:00Z" },
    "Unused section": { "referenced": 0, "last_referenced": "2025-01-01T00:00:00Z" },
    "Conventions": { "referenced": 25, "last_referenced": "2025-01-14T00:00:00Z" }
  },
  "commands_run": {},
  "docs_read": {}
}
JSON
}

make_usage_no_recs() {
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 20,
  "sections": {
    "Build commands": { "referenced": 30, "last_referenced": "2025-01-15T00:00:00Z" },
    "Unused section": { "referenced": 30, "last_referenced": "2025-01-15T00:00:00Z" },
    "Conventions": { "referenced": 25, "last_referenced": "2025-01-14T00:00:00Z" }
  },
  "commands_run": {},
  "docs_read": {}
}
JSON
}

@test "dry-run does not modify CLAUDE.md" {
  make_claudemd
  make_usage_with_remove
  original=$(cat "$REPO/CLAUDE.md")
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE" --dry-run
  [ "$status" -eq 0 ]
  after=$(cat "$REPO/CLAUDE.md")
  [ "$original" = "$after" ]
  json_output | jq -e '.dry_run == true'
}

@test "dry-run reports byte savings" {
  make_claudemd
  make_usage_with_remove
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE" --dry-run
  [ "$status" -eq 0 ]
  savings=$(json_output | jq '.savings')
  [ "$savings" -ge 0 ]
  json_output | jq -e 'has("bytes_before", "bytes_after", "savings", "applied")'
}

@test "preserves user content outside markers" {
  make_claudemd
  make_usage_with_remove
  bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE" 2>/dev/null
  grep -Fq "User content above markers." "$REPO/CLAUDE.md"
  grep -Fq "User content below markers." "$REPO/CLAUDE.md"
}

@test "no recommendations → reports zero changes" {
  make_claudemd
  make_usage_no_recs
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  applied=$(json_output | jq '.applied | length')
  [ "$applied" -eq 0 ]
}

@test "updates last_optimized timestamp" {
  make_claudemd
  make_usage_with_remove
  bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE" 2>/dev/null
  last=$(jq -r '.last_optimized // ""' "$REPO/memory/claudemd-usage.json")
  [ -n "$last" ]
}

@test "insufficient data with --force proceeds" {
  make_claudemd
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 3,
  "sections": {
    "Build commands": { "referenced": 30, "last_referenced": "2025-01-15T00:00:00Z" },
    "Unused section": { "referenced": 0, "last_referenced": "2025-01-01T00:00:00Z" },
    "Conventions": { "referenced": 25, "last_referenced": "2025-01-14T00:00:00Z" }
  },
  "commands_run": {},
  "docs_read": {}
}
JSON
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE" --force
  [ "$status" -eq 0 ]
}

@test "missing CLAUDE.md fails" {
  make_usage_with_remove
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -ne 0 ]
}

@test "CLAUDE.md without markers fails" {
  echo "# Simple CLAUDE.md" > "$REPO/CLAUDE.md"
  make_usage_with_remove
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -ne 0 ]
}

@test "missing --profile fails" {
  make_claudemd
  make_usage_with_remove
  run bash "$OPTIMIZE" --target "$REPO"
  [ "$status" -ne 0 ]
}

# ---- --force gating + section-name selection ------------------------------
# Two regressions guarding logic that's easy to silently break:
#   1. Without --force, the analyser's minimum-session guard MUST fire.
#      Bash's `${var:+x}` expansion is non-empty whenever `var` is
#      non-empty — including the literal string "false" — so the naive
#      `${force:+--force}` form forwards --force on every invocation
#      and the guard never engages.
#   2. The "add" recommendation must insert into "## How to work here"
#      (the section nyann's own gen-claudemd writes), not just into
#      "## Build". A hardcoded "## Build" pattern silently no-ops on
#      every real nyann-generated CLAUDE.md.

make_low_session_usage() {
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 1,
  "sections": {
    "Build commands": { "referenced": 1, "last_referenced": "2025-01-15T00:00:00Z" }
  },
  "commands_run": {},
  "docs_read": {}
}
JSON
}

@test "without --force, analyser refuses on insufficient sessions" {
  make_claudemd
  make_low_session_usage
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  # The "insufficient usage data" log line must appear, proving the
  # analyser saw `sufficient_data: false` and the optimiser bailed
  # before writing.
  echo "$output" | grep -Fq "insufficient usage data"
}

make_claudemd_how_to_work() {
  # Real nyann-generated CLAUDE.md uses "## How to work here", not
  # "## Build". Without the section-name fallback, the "add"
  # recommendation silently no-ops on these files.
  cat > "$REPO/CLAUDE.md" <<'MD'
# Project

<!-- nyann:start -->

## How to work here

- `npm test` — run tests

## Conventions

Commit format: conventional-commits

<!-- nyann:end -->
MD
}

make_usage_with_add_recommendation() {
  # Sessions high enough to clear the minimum, command run >=3 times
  # but absent from CLAUDE.md → triggers an "add" recommendation.
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 20,
  "sections": {
    "How to work here": { "referenced": 30, "last_referenced": "2025-01-15T00:00:00Z" },
    "Conventions": { "referenced": 25, "last_referenced": "2025-01-14T00:00:00Z" }
  },
  "commands_run": {
    "npm run typecheck": 5
  },
  "docs_read": {}
}
JSON
}

@test "add recommendation lands in '## How to work here' on real generated files" {
  make_claudemd_how_to_work
  make_usage_with_add_recommendation
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  # The new command must be inserted under "## How to work here". A
  # hardcoded "## Build" target would silently no-op on this real
  # nyann-generated layout.
  grep -Fq 'npm run typecheck' "$REPO/CLAUDE.md"
}

# ---- env-var propagation lock --------------------------------------------
# The optimiser's awk invocations previously chained `VAR=val` env-prefix
# assignments before `modified_block=$(awk ...)`. Bash treats a chain that
# ends in another assignment as shell-local — never exporting to the
# subshell — so awk's ENVIRON saw empty strings. The `remove` case then
# stripped lines indiscriminately, and the `add` case silently no-op'd.
# These tests assert that the recommendations actually mutate the file.

@test "remove recommendation actually removes the named section and keeps the rest" {
  make_claudemd
  make_usage_with_remove
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  # The "Unused section" was tagged for removal — assert it's gone but
  # the other two nyann-managed sections survive intact.
  ! grep -Fq "Unused section" "$REPO/CLAUDE.md"
  grep -Fq "Build commands"   "$REPO/CLAUDE.md"
  grep -Fq "Conventions"      "$REPO/CLAUDE.md"
  # And the original commands inside Build commands are still there
  # (proving the awk didn't strip everything between blank lines).
  grep -Fq "npm test"         "$REPO/CLAUDE.md"
  grep -Fq "npm run lint"     "$REPO/CLAUDE.md"
}

# ---- applied[] honesty lock ------------------------------------------------
# When neither `## How to work here` nor `## Build*` exists in the
# nyann block, the awk insertion is skipped. The applied[] array must
# NOT record success in that case — otherwise the optimiser claims a
# successful optimisation that never modified the file, and downstream
# consumers (memory tracking, dashboards) trust the lie.

@test "add recommendation does NOT record applied[] when no insertion target exists" {
  # CLAUDE.md has nyann markers but no "## How to work here" or "## Build*"
  # heading — the awk has nowhere to insert. The section is also
  # well-referenced so the analyser doesn't propose a removal; the
  # only recommendation is the no-target add.
  cat > "$REPO/CLAUDE.md" <<'MD'
# Project

<!-- nyann:start -->

## Some Other Section

Just text, no commands.

<!-- nyann:end -->
MD
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 20,
  "sections": {
    "Some Other Section": { "referenced": 30, "last_referenced": "2025-01-15T00:00:00Z" }
  },
  "commands_run": {
    "npm run typecheck": 5
  },
  "docs_read": {}
}
JSON
  run bash "$OPTIMIZE" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  # The cmd was NOT inserted anywhere.
  ! grep -Fq 'npm run typecheck' "$REPO/CLAUDE.md"
  # And applied[] honestly reports zero. If the script appends to
  # applied[] regardless of whether the awk actually ran, the JSON
  # claims a successful insertion that never happened — downstream
  # consumers (memory tracking, dashboards) trust the lie.
  applied=$(json_output | jq '.applied | length')
  [ "$applied" -eq 0 ]
}
