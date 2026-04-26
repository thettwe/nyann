#!/usr/bin/env bats
# Tests for bin/setup.sh — nyann user-level preferences and directory creation.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
  USER_ROOT="$TMP/nyann"
}

teardown() { rm -rf "$TMP"; }

@test "setup --check exits 2 when no preferences exist" {
  run bash "${REPO_ROOT}/bin/setup.sh" --check --user-root "$USER_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not configured"* ]]
}

@test "setup --check --json exits 2 with status field" {
  run bash "${REPO_ROOT}/bin/setup.sh" --check --json --user-root "$USER_ROOT"
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | jq -r '.status')" = "not_configured" ]
}

@test "setup creates directory structure and preferences file" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -d "$USER_ROOT/profiles" ]
  [ -d "$USER_ROOT/cache" ]
  [ -f "$USER_ROOT/preferences.json" ]
}

@test "setup writes correct default values" {
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" >/dev/null 2>&1
  prefs="$USER_ROOT/preferences.json"
  [ "$(jq -r '.schemaVersion' "$prefs")" = "1" ]
  [ "$(jq -r '.default_profile' "$prefs")" = "auto-detect" ]
  [ "$(jq -r '.branching_strategy' "$prefs")" = "auto-detect" ]
  [ "$(jq -r '.commit_format' "$prefs")" = "conventional-commits" ]
  [ "$(jq -r '.gh_integration' "$prefs")" = "true" ]
  [ "$(jq -r '.documentation_storage' "$prefs")" = "local" ]
  [ "$(jq -r '.auto_sync_team_profiles' "$prefs")" = "false" ]
  [ "$(jq -r '.setup_completed_at' "$prefs")" != "null" ]
}

@test "setup respects explicit flags" {
  bash "${REPO_ROOT}/bin/setup.sh" \
    --user-root "$USER_ROOT" \
    --default-profile fastapi-service \
    --branching-strategy gitflow \
    --commit-format custom \
    --no-gh-integration \
    --documentation-storage obsidian \
    --auto-sync-team-profiles \
    >/dev/null 2>&1
  prefs="$USER_ROOT/preferences.json"
  [ "$(jq -r '.default_profile' "$prefs")" = "fastapi-service" ]
  [ "$(jq -r '.branching_strategy' "$prefs")" = "gitflow" ]
  [ "$(jq -r '.commit_format' "$prefs")" = "custom" ]
  [ "$(jq -r '.gh_integration' "$prefs")" = "false" ]
  [ "$(jq -r '.documentation_storage' "$prefs")" = "obsidian" ]
  [ "$(jq -r '.auto_sync_team_profiles' "$prefs")" = "true" ]
}

@test "setup --json emits structured result" {
  run bash "${REPO_ROOT}/bin/setup.sh" --json --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "ok" ]
  [ "$(echo "$output" | jq -r '.preferences.default_profile')" = "auto-detect" ]
  [ "$(echo "$output" | jq -r '.preferences.schemaVersion')" = "1" ]
}

@test "setup --check shows configured after write" {
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile go-service >/dev/null 2>&1
  run bash "${REPO_ROOT}/bin/setup.sh" --check --json --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "configured" ]
  [ "$(echo "$output" | jq -r '.preferences.default_profile')" = "go-service" ]
  [ "$(echo "$output" | jq -r '.directories_ok')" = "true" ]
}

@test "setup is idempotent — re-running overwrites cleanly" {
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile rust-cli >/dev/null 2>&1
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile node-api >/dev/null 2>&1
  [ "$(jq -r '.default_profile' "$USER_ROOT/preferences.json")" = "node-api" ]
}

@test "setup rejects invalid branching strategy" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --branching-strategy invalid
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --branching-strategy"* ]]
}

@test "setup rejects invalid commit format" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --commit-format invalid
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --commit-format"* ]]
}

@test "setup rejects invalid documentation storage" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --documentation-storage invalid
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --documentation-storage"* ]]
}

@test "setup rejects invalid profile name" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile "INVALID NAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --default-profile"* ]]
}

@test "setup accepts namespaced profile name" {
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile team/my-profile >/dev/null 2>&1
  [ "$(jq -r '.default_profile' "$USER_ROOT/preferences.json")" = "team/my-profile" ]
}

@test "preferences file has restrictive permissions" {
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" >/dev/null 2>&1
  perms=$(stat -f '%Lp' "$USER_ROOT/preferences.json" 2>/dev/null || stat -c '%a' "$USER_ROOT/preferences.json" 2>/dev/null)
  [ "$perms" = "600" ]
}
