#!/usr/bin/env bats
# bin/settings.sh — show + set behavior for the interactive menu backend.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-settings.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  USER_ROOT="$TMP/user-root"
  mkdir -p "$USER_ROOT"
  jq -n '{
    schemaVersion: 2,
    default_profile: "auto-detect",
    branching_strategy: "auto-detect",
    commit_format: "conventional-commits",
    gh_integration: true,
    documentation_storage: "local",
    auto_sync_team_profiles: false,
    git_identity: { name: "T", email: "t@t", confirmed: false },
    session_triage: true,
    guard_default_severity: "advisory",
    notifications: { sentinel: true, staleness_alerts: true },
    setup_completed_at: "2026-05-28T00:00:00Z"
  }' > "$USER_ROOT/preferences.json"
}

teardown() { rm -rf "$TMP"; }

@test "show prints all current settings" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --show
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "default_profile"
  echo "$output" | grep -q "session_triage"
  echo "$output" | grep -q "notifications.sentinel"
  echo "$output" | grep -q "guard_default_severity"
}

@test "show --json emits preferences verbatim" {
  out=$(bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --show --json)
  echo "$out" | jq -e '.schemaVersion == 2'
  echo "$out" | jq -e '.session_triage == true'
}

@test "set updates one field and preserves others" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set session_triage false
  [ "$status" -eq 0 ]
  prefs="$USER_ROOT/preferences.json"
  jq -e '.session_triage == false' "$prefs"
  jq -e '.guard_default_severity == "advisory"' "$prefs"
  jq -e '.default_profile == "auto-detect"' "$prefs"
}

@test "set updates a nested key (notifications.sentinel)" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set notifications.sentinel false
  [ "$status" -eq 0 ]
  jq -e '.notifications.sentinel == false' "$USER_ROOT/preferences.json"
  jq -e '.notifications.staleness_alerts == true' "$USER_ROOT/preferences.json"
}

@test "set rejects an invalid key" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set bogus_key true
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown key"
}

@test "set rejects an invalid value for enum field" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set guard_default_severity bogus
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid value"
}

@test "set rejects non-boolean for boolean field" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set session_triage maybe
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid value"
}

@test "set bumps schemaVersion to 2 on a v1 file" {
  jq -n '{schemaVersion: 1, default_profile: "auto-detect", branching_strategy: "auto-detect", commit_format: "conventional-commits", gh_integration: true, documentation_storage: "local", auto_sync_team_profiles: false, setup_completed_at: "2026-01-01T00:00:00Z"}' \
    > "$USER_ROOT/preferences.json"
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set session_triage false
  [ "$status" -eq 0 ]
  v=$(jq -r .schemaVersion "$USER_ROOT/preferences.json"); [ "$v" -eq 2 ]
}

@test "show errors when preferences.json missing" {
  rm -f "$USER_ROOT/preferences.json"
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --show
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "preferences not found"
}

@test "show renders a stored 'false' boolean as false, never as enabled" {
  # `// true` would mask a disabled feature — regression guard. Disable a
  # few booleans on disk and confirm the human table reflects the real value.
  jq '.session_triage = false
      | .gh_integration = false
      | .notifications.sentinel = false
      | .notifications.staleness_alerts = false' \
    "$USER_ROOT/preferences.json" > "$USER_ROOT/preferences.json.tmp"
  mv "$USER_ROOT/preferences.json.tmp" "$USER_ROOT/preferences.json"
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --show
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq '^session_triage +false$'
  echo "$output" | grep -Eq '^gh_integration +false$'
  echo "$output" | grep -Eq '^notifications.sentinel +false$'
  echo "$output" | grep -Eq '^notifications.staleness_alerts +false$'
}

@test "set with a key but no value gives the friendly error (not a shift abort)" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" --set session_triage
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires a <value>"
}

@test "set rejects CR/LF in email.to (RFC822 header injection)" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" \
    --set notifications.delivery.email.to "$(printf 'ops@team.test\nBcc: evil@x.test')"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "CR/LF"
  # File untouched — the injection never reached the stored value.
  jq -e '.notifications.delivery == null' "$USER_ROOT/preferences.json"
}

@test "set rejects CR/LF in email.from (RFC822 header injection)" {
  run bash "$REPO_ROOT/bin/settings.sh" --user-root "$USER_ROOT" \
    --set notifications.delivery.email.from "$(printf 'nyann@team.test\rSubject: spoofed')"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "CR/LF"
}
