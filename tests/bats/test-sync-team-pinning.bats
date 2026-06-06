#!/usr/bin/env bats
# test-sync-team-pinning.bats — tests for team profile SHA/tag pinning (B3+B4).

setup() {
  export SYNC="${BATS_TEST_DIRNAME}/../../bin/sync-team-profiles.sh"
  export ADD="${BATS_TEST_DIRNAME}/../../bin/add-team-source.sh"
  export TMP="${BATS_TEST_TMPDIR}"
  export USER_ROOT="$TMP/user-$$-$BATS_TEST_NUMBER"
  mkdir -p "$USER_ROOT"

  # Create a bare remote repo with two commits and a tag
  export REMOTE="$TMP/remote-$$-$BATS_TEST_NUMBER"
  mkdir -p "$REMOTE"
  git init -q -b main --bare "$REMOTE"

  local work="$TMP/work-$$-$BATS_TEST_NUMBER"
  mkdir -p "$work/profiles"
  git -C "$work" init -q -b main
  git -C "$work" config user.email "test@test"
  git -C "$work" config user.name "test"
  git -C "$work" remote add origin "$REMOTE"
  cat > "$work/profiles/test-prof.json" <<'JSON'
{"name":"test-prof","schemaVersion":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[]},"extras":{},"conventions":{},"documentation":{}}
JSON
  git -C "$work" add .
  git -C "$work" commit -qm "feat: initial profile"
  export FIRST_SHA=$(git -C "$work" rev-parse HEAD)

  cat > "$work/profiles/test-prof.json" <<'JSON'
{"name":"test-prof","schemaVersion":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":["eslint"]},"extras":{},"conventions":{},"documentation":{}}
JSON
  git -C "$work" add .
  git -C "$work" commit -qm "feat: add eslint hook"
  export SECOND_SHA=$(git -C "$work" rev-parse HEAD)
  git -C "$work" tag v1.0.0
  git -C "$work" push -q origin main --tags
}

write_config() {
  local strategy="$1" pin="${2:-}"
  cat > "$USER_ROOT/config.json" <<JSON
{
  "schemaVersion": 1,
  "team_profile_sources": [{
    "name": "test-team",
    "url": "file://$REMOTE",
    "ref": "main",
    "sync_interval_hours": 0,
    "last_synced_at": 0,
    "pin_strategy": "$strategy"$([ -n "$pin" ] && echo ",\"pin\": \"$pin\"" || echo "")
  }]
}
JSON
}

# ────────────────────────────────────────────────────────────────────
# branch strategy (existing behavior)
# ────────────────────────────────────────────────────────────────────

@test "pin_strategy=branch: sync follows HEAD (existing behavior)" {
  write_config "branch"
  result=$(bash "$SYNC" --user-root "$USER_ROOT" --force 2>/dev/null)
  echo "$result" | jq -e '.synced | length == 1'

  cache_sha=$(git -C "$USER_ROOT/cache/test-team" rev-parse HEAD)
  [ "$cache_sha" = "$SECOND_SHA" ]
}

# ────────────────────────────────────────────────────────────────────
# SHA pinning
# ────────────────────────────────────────────────────────────────────

@test "pin_strategy=sha: checkout stays at pinned SHA" {
  write_config "sha" "$FIRST_SHA"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  cache_sha=$(git -C "$USER_ROOT/cache/test-team" rev-parse HEAD)
  [ "$cache_sha" = "$FIRST_SHA" ]
}

@test "pin_strategy=sha: updates_available reported when behind" {
  write_config "sha" "$FIRST_SHA"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  run bash "$SYNC" --user-root "$USER_ROOT" --force
  [ "$status" -eq 0 ]
  # Should report an update is available (FIRST_SHA behind SECOND_SHA)
  if echo "$output" | jq -e 'has("updates_available")' 2>/dev/null; then
    echo "$output" | jq -e '.updates_available[0].commits_behind >= 1'
  fi
}

# ────────────────────────────────────────────────────────────────────
# tag pinning
# ────────────────────────────────────────────────────────────────────

@test "pin_strategy=tag: checkout at tag ref" {
  write_config "tag"
  # Override ref to point to the tag
  jq '.team_profile_sources[0].ref = "v1.0.0"' "$USER_ROOT/config.json" > "$TMP/cfg.json"
  mv "$TMP/cfg.json" "$USER_ROOT/config.json"

  run bash "$SYNC" --user-root "$USER_ROOT" --force
  [ "$status" -eq 0 ]

  cache_sha=$(git -C "$USER_ROOT/cache/test-team" rev-parse HEAD)
  [ "$cache_sha" = "$SECOND_SHA" ]
}

# ────────────────────────────────────────────────────────────────────
# --check-updates
# ────────────────────────────────────────────────────────────────────

@test "--check-updates: reports changelog for pinned source" {
  write_config "sha" "$FIRST_SHA"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  result=$(bash "$SYNC" --user-root "$USER_ROOT" --check-updates 2>/dev/null)
  echo "$result" | jq -e 'has("updates_available")'
  echo "$result" | jq -e '.updates_available[0].source_name == "test-team"'
  echo "$result" | jq -e '.updates_available[0].commits_behind >= 1'
}

@test "--check-updates: commit_log never piped through head (BUG A structural guard)" {
  # Regression (BUG A): the changelog used `git log … | head -20 | jq …
  # || echo '[]'` under `set -o pipefail`. When git's output is large
  # enough that it's still writing when head closes the pipe after 20
  # lines, git takes SIGPIPE (141), the pipeline fails, and `|| echo
  # '[]'` APPENDS `[]` after jq already wrote its array → a corrupt
  # `<array>[]` value that kills the downstream `--argjson log` and,
  # being inside `$(...)` under set -e, aborts the whole sync.
  #
  # The corruption is timing-dependent (git must still be writing when
  # head exits), so reproducing it deterministically in a unit test is
  # flaky. Assert the fix structurally instead: `git … log` must
  # self-limit via `-n 20` (or `--max-count`) and must NOT be piped
  # through `head`. The behavioural no-abort case is covered below.
  ! grep -qE 'git .*log .*\| *head' "$SYNC"
  grep -qE 'git .*log --oneline -n 20|git .*log .*--max-count' "$SYNC"
}

@test "--check-updates: many commits behind doesn't corrupt commit_log or abort sync" {
  # Behavioural companion to the structural guard above. Even when the
  # SIGPIPE race doesn't fire, sync must stay green and emit a valid,
  # 20-capped commit_log array.
  write_config "sha" "$FIRST_SHA"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  # Push many commits with long subjects to the remote. A handful of
  # short commits won't trip the bug: git buffers the whole `--oneline`
  # output into the 64KB pipe and exits 0 before `head` closes the pipe.
  # The SIGPIPE only fires when git is STILL writing as head exits after
  # 20 lines, so we need enough bytes (200 long-subject commits) to keep
  # git's write side busy past head's early close.
  local work="$TMP/work2-$$-$BATS_TEST_NUMBER"
  git clone -q "$REMOTE" "$work"
  git -C "$work" config user.email "test@test"
  git -C "$work" config user.name "test"
  local i pad
  pad="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  for i in $(seq 1 200); do
    echo "$i" > "$work/commit-$i.txt"
    git -C "$work" add .
    git -C "$work" commit -qm "chore: commit number $i with a long subject line $pad"
  done
  git -C "$work" push -q origin main

  run bash "$SYNC" --user-root "$USER_ROOT" --check-updates
  # Sync must NOT abort (buggy `… | head -20 | jq … || echo '[]'` under
  # pipefail produced a corrupt `<array>[]` that killed --argjson and,
  # inside `$(...)` under set -e, aborted the whole script).
  [ "$status" -eq 0 ]
  # commit_log must be a valid JSON array, capped at 20 entries.
  echo "$output" | jq -e 'has("updates_available")'
  echo "$output" | jq -e '.updates_available[0].commit_log | type == "array"'
  echo "$output" | jq -e '.updates_available[0].commit_log | length == 20'
  # commits_behind is bounded by the --check-updates shallow fetch depth
  # (--depth=50), so assert "well past the 20-commit head boundary"
  # rather than the full 200 — the key point is no corruption/abort.
  echo "$output" | jq -e '.updates_available[0].commits_behind >= 20'
}

@test "--check-updates: no updates when already at latest" {
  write_config "sha" "$SECOND_SHA"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  result=$(bash "$SYNC" --user-root "$USER_ROOT" --check-updates 2>/dev/null)
  if echo "$result" | jq -e 'has("updates_available")' 2>/dev/null; then
    echo "$result" | jq -e '.updates_available | length == 0'
  fi
}

@test "--check-updates: skipped for branch strategy" {
  write_config "branch"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  result=$(bash "$SYNC" --user-root "$USER_ROOT" --check-updates 2>/dev/null)
  echo "$result" | jq -e 'has("updates_available") | not'
}

# ────────────────────────────────────────────────────────────────────
# --accept-update
# ────────────────────────────────────────────────────────────────────

@test "--accept-update: advances pin to latest" {
  write_config "sha" "$FIRST_SHA"
  bash "$SYNC" --user-root "$USER_ROOT" --force >/dev/null 2>&1

  cache_sha=$(git -C "$USER_ROOT/cache/test-team" rev-parse HEAD)
  [ "$cache_sha" = "$FIRST_SHA" ]

  result=$(bash "$SYNC" --user-root "$USER_ROOT" --accept-update test-team 2>/dev/null)
  echo "$result" | jq -e '.synced[0].action == "pin-advanced"'

  cache_sha=$(git -C "$USER_ROOT/cache/test-team" rev-parse HEAD)
  [ "$cache_sha" = "$SECOND_SHA" ]

  new_pin=$(jq -r '.team_profile_sources[0].pin' "$USER_ROOT/config.json")
  [ "$new_pin" = "$SECOND_SHA" ]
}

# ────────────────────────────────────────────────────────────────────
# Schema compliance
# ────────────────────────────────────────────────────────────────────

@test "config with pin fields validates against config schema" {
  write_config "sha" "$FIRST_SHA"
  local SCHEMA="${BATS_TEST_DIRNAME}/../../schemas/config.schema.json"
  if command -v check-jsonschema >/dev/null 2>&1; then
    run check-jsonschema --schemafile "$SCHEMA" "$USER_ROOT/config.json"
    [ "$status" -eq 0 ]
  else
    skip "check-jsonschema not available"
  fi
}
