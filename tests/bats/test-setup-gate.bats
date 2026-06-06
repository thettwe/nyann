#!/usr/bin/env bats
# nyann::require_setup behavior + setup.sh writes the v2 schema fields.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-gate.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  USER_ROOT="$TMP/user-root"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
}

teardown() { rm -rf "$TMP"; }

@test "require_setup returns 2 when preferences.json is missing" {
  # Neutralize CI/non-interactive markers: under those, require_setup
  # intentionally synthesizes a defaults file (rc 0). GitHub Actions sets
  # CI=true globally, so without this unset the assertion can never hold
  # on CI even though the local-developer path returns 2 correctly.
  run bash -c "unset CI NYANN_NONINTERACTIVE; source '$REPO_ROOT/bin/_lib.sh'; NYANN_USER_ROOT='$USER_ROOT' nyann::require_setup test-skill"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "nyann setup required"
}

@test "require_setup returns 0 when preferences.json exists" {
  mkdir -p "$USER_ROOT"
  echo '{"schemaVersion":2}' > "$USER_ROOT/preferences.json"
  run bash -c "source '$REPO_ROOT/bin/_lib.sh'; NYANN_USER_ROOT='$USER_ROOT' nyann::require_setup test-skill"
  [ "$status" -eq 0 ]
}

@test "require_setup auto-creates defaults in CI mode" {
  run bash -c "CI=true; source '$REPO_ROOT/bin/_lib.sh'; NYANN_USER_ROOT='$USER_ROOT' nyann::require_setup test-skill"
  [ "$status" -eq 0 ]
  [ -f "$USER_ROOT/preferences.json" ]
  v=$(jq -r .schemaVersion "$USER_ROOT/preferences.json")
  [ "$v" -ge 2 ]
}

@test "require_setup honors NYANN_NONINTERACTIVE" {
  run bash -c "NYANN_NONINTERACTIVE=true; source '$REPO_ROOT/bin/_lib.sh'; NYANN_USER_ROOT='$USER_ROOT' nyann::require_setup test-skill"
  [ "$status" -eq 0 ]
  [ -f "$USER_ROOT/preferences.json" ]
  triage=$(jq -r .session_triage "$USER_ROOT/preferences.json")
  [ "$triage" = "true" ]
}

@test "setup writes v2 schema with all proactive-awareness fields" {
  run bash "$REPO_ROOT/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile auto-detect \
    --branching-strategy auto-detect \
    --commit-format conventional-commits \
    --no-gh-integration \
    --documentation-storage local
  [ "$status" -eq 0 ]
  prefs="$USER_ROOT/preferences.json"
  [ -f "$prefs" ]
  v=$(jq -r .schemaVersion "$prefs"); [ "$v" -eq 2 ]
  jq -e '.session_triage == true' "$prefs"
  jq -e '.guard_default_severity == "advisory"' "$prefs"
  jq -e '.notifications.sentinel == true' "$prefs"
  jq -e '.notifications.staleness_alerts == true' "$prefs"
  jq -e 'has("git_identity")' "$prefs"
}

@test "setup honors --no-session-triage" {
  run bash "$REPO_ROOT/bin/setup.sh" --user-root "$USER_ROOT" --no-session-triage --no-gh-integration
  [ "$status" -eq 0 ]
  jq -e '.session_triage == false' "$USER_ROOT/preferences.json"
}

@test "setup honors --guard-default-severity confirm" {
  run bash "$REPO_ROOT/bin/setup.sh" --user-root "$USER_ROOT" --guard-default-severity confirm --no-gh-integration
  [ "$status" -eq 0 ]
  jq -e '.guard_default_severity == "confirm"' "$USER_ROOT/preferences.json"
}

@test "setup rejects invalid guard severity" {
  run bash "$REPO_ROOT/bin/setup.sh" --user-root "$USER_ROOT" --guard-default-severity bogus
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid --guard-default-severity"
}

@test "incremental upgrade preserves existing fields" {
  # Seed a v1 preferences.json from the old shape.
  mkdir -p "$USER_ROOT"
  jq -n '{
    schemaVersion: 1,
    default_profile: "node-api",
    branching_strategy: "trunk-based",
    commit_format: "conventional-commits",
    gh_integration: true,
    documentation_storage: "obsidian",
    auto_sync_team_profiles: true,
    setup_completed_at: "2026-01-01T00:00:00Z"
  }' > "$USER_ROOT/preferences.json"

  run bash "$REPO_ROOT/bin/setup.sh" --user-root "$USER_ROOT" \
    --incremental --fields session_triage --no-session-triage
  [ "$status" -eq 0 ]
  # New field set.
  jq -e '.session_triage == false' "$USER_ROOT/preferences.json"
  # Old fields preserved.
  jq -e '.default_profile == "node-api"' "$USER_ROOT/preferences.json"
  jq -e '.branching_strategy == "trunk-based"' "$USER_ROOT/preferences.json"
  jq -e '.documentation_storage == "obsidian"' "$USER_ROOT/preferences.json"
  jq -e '.auto_sync_team_profiles == true' "$USER_ROOT/preferences.json"
  # Schema bumped.
  v=$(jq -r .schemaVersion "$USER_ROOT/preferences.json"); [ "$v" -eq 2 ]
}

@test "--check exits 2 when no preferences exist (human mode)" {
  # Documented contract: exit 2 — no preferences.json found yet.
  run bash "$REPO_ROOT/bin/setup.sh" --check --user-root "$USER_ROOT"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "not configured"
}

@test "--check exits 2 when no preferences exist (json mode)" {
  run bash "$REPO_ROOT/bin/setup.sh" --check --json --user-root "$USER_ROOT"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.status == "not_configured"'
}

@test "--check exits 0 when preferences exist" {
  mkdir -p "$USER_ROOT/profiles" "$USER_ROOT/cache"
  echo '{"schemaVersion":2}' > "$USER_ROOT/preferences.json"
  run bash "$REPO_ROOT/bin/setup.sh" --check --json --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "configured"'
}

@test "prefs_schema_version returns 0 when missing" {
  v=$(bash -c "source '$REPO_ROOT/bin/_lib.sh'; NYANN_USER_ROOT='$USER_ROOT' nyann::prefs_schema_version")
  [ "$v" = "0" ]
}

@test "prefs_schema_version returns stored value" {
  mkdir -p "$USER_ROOT"
  echo '{"schemaVersion":2}' > "$USER_ROOT/preferences.json"
  v=$(bash -c "source '$REPO_ROOT/bin/_lib.sh'; NYANN_USER_ROOT='$USER_ROOT' nyann::prefs_schema_version")
  [ "$v" = "2" ]
}
