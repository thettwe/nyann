#!/usr/bin/env bats
# bin/claude-hook-block-main.sh — matcher + decision matrix.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HOOK="${REPO_ROOT}/bin/claude-hook-block-main.sh"
  TMP="$(mktemp -d)"
  ( cd "$TMP" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
}

teardown() { rm -rf "$TMP"; }

@test "on main + git commit → exit 2" {
  cd "$TMP"
  run bash "$HOOK" 'git commit -m "feat: x"'
  [ "$status" -eq 2 ]
}

@test "on main + git commit --no-verify → exit 0 (escape hatch)" {
  cd "$TMP"
  run bash "$HOOK" 'git commit --no-verify -m "feat: x"'
  [ "$status" -eq 0 ]
}

@test "on main + non-commit command (git status) → exit 0" {
  cd "$TMP"
  run bash "$HOOK" 'git status'
  [ "$status" -eq 0 ]
}

@test "on feature branch + git commit → exit 0" {
  cd "$TMP"
  git checkout -q -b feat/test
  run bash "$HOOK" 'git commit -m "feat: x"'
  [ "$status" -eq 0 ]
}

@test "on main + git push → exit 2" {
  cd "$TMP"
  run bash "$HOOK" 'git push origin main'
  [ "$status" -eq 2 ]
}

@test "accepts Claude Code JSON stdin shape" {
  cd "$TMP"
  run bash -c "echo '{\"tool_input\":{\"command\":\"git commit -m \\\"feat: x\\\"\"}}' | bash '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "empty stdin / no arg → exit 0 (defensive pass-through)" {
  cd "$TMP"
  run bash -c "'$HOOK' </dev/null"
  [ "$status" -eq 0 ]
}

@test "stderr message names the blocking command verb" {
  cd "$TMP"
  run bash "$HOOK" 'git commit -m "feat: x"'
  [ "$status" -eq 2 ]
  echo "$output" | grep -qE 'Blocked: direct (commit|push)'
}

@test "non-JSON stdin containing 'git commit' does NOT trigger a block" {
  # Regression: on jq parse failure the script used to fall back to
  # treating raw stdin as $cmd, so a log line mentioning "git commit"
  # would trigger a false block even on main.
  cd "$TMP"
  run bash -c "printf 'some log line mentioning git commit -m here\n' | bash '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "malformed JSON stdin → exit 0 (not a false block)" {
  cd "$TMP"
  run bash -c "printf '{not json' | bash '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "JSON stdin without command field → exit 0" {
  cd "$TMP"
  run bash -c "echo '{\"tool_input\":{\"other\":\"value\"}}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
}
