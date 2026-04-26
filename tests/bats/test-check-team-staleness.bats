#!/usr/bin/env bats
# Tests for bin/check-team-staleness.sh — team profile staleness monitor.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  STALENESS="${REPO_ROOT}/bin/check-team-staleness.sh"
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
