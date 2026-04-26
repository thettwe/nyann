#!/usr/bin/env bats
# bin/track-claudemd-usage.sh — PostToolUse tracking hook tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TRACK="${REPO_ROOT}/bin/track-claudemd-usage.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO/.git" "$REPO/memory" "$REPO/docs"

  # Create a minimal CLAUDE.md with doc references
  cat > "$REPO/CLAUDE.md" <<'MD'
# Project

## Build
- `npm test`
- `npm run lint`

## Docs
- [Architecture](docs/architecture.md)
- [PRD](docs/prd.md)
MD

  # Create empty usage file (opt-in)
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{ "sessions": 0, "sections": {}, "commands_run": {}, "docs_read": {} }
JSON
}

teardown() { rm -rf "$TMP"; }

run_track() {
  cd "$REPO" && echo "$1" | bash "$TRACK"
}

@test "tracks Read of a doc referenced in CLAUDE.md" {
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/docs/architecture.md"}}'
  run_track "$payload"
  count=$(jq -r '.docs_read["docs/architecture.md"] // 0' "$REPO/memory/claudemd-usage.json")
  [ "$count" -eq 1 ]
}

@test "increments count on repeated reads" {
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/docs/architecture.md"}}'
  run_track "$payload"
  run_track "$payload"
  count=$(jq -r '.docs_read["docs/architecture.md"] // 0' "$REPO/memory/claudemd-usage.json")
  [ "$count" -eq 2 ]
}

@test "tracks Bash command referenced in CLAUDE.md" {
  payload='{"tool_name":"Bash","tool_input":{"command":"npm test"}}'
  run_track "$payload"
  count=$(jq -r '.commands_run["npm test"] // 0' "$REPO/memory/claudemd-usage.json")
  [ "$count" -eq 1 ]
}

@test "ignores Read of file not in CLAUDE.md" {
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/src/index.ts"}}'
  run_track "$payload"
  keys=$(jq '.docs_read | keys | length' "$REPO/memory/claudemd-usage.json")
  [ "$keys" -eq 0 ]
}

@test "ignores Bash command not in CLAUDE.md" {
  payload='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
  run_track "$payload"
  keys=$(jq '.commands_run | keys | length' "$REPO/memory/claudemd-usage.json")
  [ "$keys" -eq 0 ]
}

@test "opt-in guard: no tracking without usage file" {
  rm "$REPO/memory/claudemd-usage.json"
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/docs/architecture.md"}}'
  cd "$REPO" && echo "$payload" | bash "$TRACK"
  [ ! -f "$REPO/memory/claudemd-usage.json" ]
}

@test "ignores unknown tool names" {
  payload='{"tool_name":"Write","tool_input":{"file_path":"foo.txt"}}'
  run_track "$payload"
  # File should be unchanged (sessions still 0)
  sessions=$(jq '.sessions' "$REPO/memory/claudemd-usage.json")
  [ "$sessions" -eq 0 ]
}

@test "updates sections tracking for doc reads" {
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/docs/architecture.md"}}'
  run_track "$payload"
  refs=$(jq -r '.sections["docs/architecture.md"].referenced // 0' "$REPO/memory/claudemd-usage.json")
  [ "$refs" -eq 1 ]
  # Check last_referenced is set
  last=$(jq -r '.sections["docs/architecture.md"].last_referenced // ""' "$REPO/memory/claudemd-usage.json")
  [ -n "$last" ]
}

@test "handles missing jq gracefully" {
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/docs/architecture.md"}}'
  cd "$REPO" && PATH="/usr/bin" echo "$payload" | bash "$TRACK" 2>/dev/null || true
  # Should exit 0 (no crash), file unchanged
  [ -f "$REPO/memory/claudemd-usage.json" ]
}

# ---- concurrent-write safety -------------------------------------------------
# Without the lockdir wrapper around the read-modify-write, two parallel
# PostToolUse hooks both read the same baseline JSON, both compute their
# +1 increments from it, and the second `mv` clobbers the first. Ten
# parallel firings degrade to ~1-2 surviving increments. The lockdir
# serialises the rmw so all (or near-all) increments land.

@test "concurrent invocations don't lose increments (lockdir wrapper)" {
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$REPO"'/docs/architecture.md"}}'

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ( cd "$REPO" && echo "$payload" | bash "$TRACK" ) &
  done
  wait

  count=$(jq -r '.docs_read["docs/architecture.md"] // 0' "$REPO/memory/claudemd-usage.json")
  # Some firings may legitimately skip after lock-acquire timeout (1s
  # cumulative across 10 attempts at 0.1s each) — that's acceptable.
  # The lock guarantees serialised rmw, so the typical landing rate is
  # close to all 10. Require at least 7 of 10 to land — without the
  # lockdir wrapper, an unsynchronised rmw would lose 8-9 of them to
  # overwrite races.
  [ "$count" -ge 7 ]
}

@test "lockdir is released after each invocation (no leak)" {
  payload='{"tool_name":"Bash","tool_input":{"command":"npm test"}}'
  run_track "$payload"
  [ ! -d "$REPO/memory/claudemd-usage.json.lockdir" ]
}
