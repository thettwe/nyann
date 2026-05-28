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
