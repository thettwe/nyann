#!/usr/bin/env bats
# Tests for bin/check-team-staleness.sh — team profile staleness monitor.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  STALENESS="${REPO_ROOT}/bin/check-team-staleness.sh"
  DRIFT="${REPO_ROOT}/bin/check-team-drift.sh"
  TMP=$(mktemp -d -t nyann-staleness.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  USER_ROOT="$TMP/nyann-home"
}

teardown() { rm -rf "$TMP"; }

@test "exits silently when no config.json exists" {
  mkdir -p "$USER_ROOT"
  run bash "$STALENESS" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits silently when config has no team sources" {
  mkdir -p "$USER_ROOT"
  echo '{"team_profile_sources":[]}' > "$USER_ROOT/config.json"
  run bash "$STALENESS" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits silently when config is missing team_profile_sources key" {
  mkdir -p "$USER_ROOT"
  echo '{}' > "$USER_ROOT/config.json"
  run bash "$STALENESS" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emits notification when team source has drifted" {
  # Set up a fake team source with a local git repo as the "remote".
  REMOTE="$TMP/remote-repo"
  mkdir -p "$REMOTE"
  ( cd "$REMOTE" && git init -q -b main && \
    mkdir -p profiles && \
    echo '{"name":"test-profile","schemaVersion":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"extras":{},"conventions":{"commit_format":"conventional-commits"},"documentation":{"scaffold_types":[],"storage_strategy":"local","claude_md_mode":"router"}}' \
      > profiles/test-profile.json && \
    git add -A && \
    git -c user.email=test@test.com -c user.name=test \
    commit -q -m "initial" )

  # Register the source and sync.
  mkdir -p "$USER_ROOT"
  bash "${REPO_ROOT}/bin/add-team-source.sh" \
    --name test-team --url "file://$REMOTE" --ref main \
    --user-root "$USER_ROOT" >/dev/null 2>&1
  bash "${REPO_ROOT}/bin/sync-team-profiles.sh" \
    --user-root "$USER_ROOT" --force >/dev/null 2>&1

  # Now mutate the remote so it drifts.
  ( cd "$REMOTE" && \
    jq '.stack.primary_language = "python"' profiles/test-profile.json > profiles/tmp.json && \
    mv profiles/tmp.json profiles/test-profile.json && \
    git add -A && \
    git -c user.email=test@test.com -c user.name=test \
    commit -q -m "update profile" )

  run bash "$STALENESS" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[nyann]"* ]]
  [[ "$output" == *"team profile"* ]]
  [[ "$output" == *"upstream changes"* ]]
  [[ "$output" == *"/nyann:sync-team-profiles"* ]]
}

# BUG B + C: the drift fetch (which the background monitor invokes) must
# be (1) wrapped in a timeout so a stalled remote can't hang the monitor
# forever, and (2) hoisted ABOVE the per-profile `for pf` loop so N
# cached profiles don't trigger N network fetches per check. These are
# hard to assert against a real stall, so we verify the source structure.
@test "drift checker: fetch is timeout-wrapped (monitor must never block)" {
  # A timeout/gtimeout chain must guard the fetch.
  grep -q 'timeout .*git' "$DRIFT" || grep -qE 'timeout[^|]*"\$\{fetch\[@\]\}"|fetch=\(timeout' "$DRIFT"
}

@test "drift checker: fetch is hoisted out of the per-profile loop (single fetch)" {
  # The `git … fetch` line must appear BEFORE the `for pf` profile loop,
  # not inside it — one fetch per source, not one per cached profile.
  fetch_line=$(grep -n 'fetch --quiet' "$DRIFT" | head -1 | cut -d: -f1)
  loop_line=$(grep -n 'for pf in' "$DRIFT" | head -1 | cut -d: -f1)
  [ -n "$fetch_line" ]
  [ -n "$loop_line" ]
  [ "$fetch_line" -lt "$loop_line" ]
}

@test "drift checker: only one fetch per source even with multiple profiles" {
  # Two cached profiles in one source must trigger exactly one fetch.
  REMOTE="$TMP/remote-repo"
  mkdir -p "$REMOTE/profiles"
  prof() {
    echo '{"name":"'"$1"'","schemaVersion":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"extras":{},"conventions":{"commit_format":"conventional-commits"},"documentation":{"scaffold_types":[],"storage_strategy":"local","claude_md_mode":"router"}}'
  }
  ( cd "$REMOTE" && git init -q -b main && \
    prof one > profiles/one.json && prof two > profiles/two.json && \
    git add -A && \
    git -c user.email=test@test.com -c user.name=test commit -q -m "initial" )

  mkdir -p "$USER_ROOT"
  bash "${REPO_ROOT}/bin/add-team-source.sh" \
    --name multi --url "file://$REMOTE" --ref main \
    --user-root "$USER_ROOT" >/dev/null 2>&1
  bash "${REPO_ROOT}/bin/sync-team-profiles.sh" \
    --user-root "$USER_ROOT" --force >/dev/null 2>&1

  # Shim git to count `fetch` invocations.
  REAL_GIT="$(command -v git)"
  SHIM="$TMP/shim"
  mkdir -p "$SHIM"
  COUNT="$TMP/fetch-count"
  : > "$COUNT"
  cat > "$SHIM/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == "fetch" ]]; then echo x >> "$COUNT"; break; fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$SHIM/git"

  PATH="$SHIM:$PATH" bash "$DRIFT" --user-root "$USER_ROOT" >/dev/null 2>&1
  [ "$(wc -l < "$COUNT" | tr -d ' ')" -eq 1 ]
}

@test "exits silently when team source is up to date" {
  REMOTE="$TMP/remote-repo"
  mkdir -p "$REMOTE"
  ( cd "$REMOTE" && git init -q -b main && \
    mkdir -p profiles && \
    echo '{"name":"fresh","schemaVersion":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"extras":{},"conventions":{"commit_format":"conventional-commits"},"documentation":{"scaffold_types":[],"storage_strategy":"local","claude_md_mode":"router"}}' \
      > profiles/fresh.json && \
    git add -A && \
    git -c user.email=test@test.com -c user.name=test \
    commit -q -m "initial" )

  mkdir -p "$USER_ROOT"
  bash "${REPO_ROOT}/bin/add-team-source.sh" \
    --name fresh-team --url "file://$REMOTE" --ref main \
    --user-root "$USER_ROOT" >/dev/null 2>&1
  bash "${REPO_ROOT}/bin/sync-team-profiles.sh" \
    --user-root "$USER_ROOT" --force >/dev/null 2>&1

  # No remote mutation → should be silent.
  run bash "$STALENESS" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
