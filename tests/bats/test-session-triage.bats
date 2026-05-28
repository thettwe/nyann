#!/usr/bin/env bats
# Session triage (P1) — wrapper + fingerprint dedup in session-check.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-triage.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  USER_ROOT="$TMP/user-root"
  REPO="$TMP/repo"
  export NYANN_USER_ROOT="$USER_ROOT"
  mkdir -p "$USER_ROOT/cache" "$REPO"
  jq -n '{
    schemaVersion: 2,
    default_profile: "node-api",
    branching_strategy: "auto-detect",
    commit_format: "conventional-commits",
    gh_integration: false,
    documentation_storage: "local",
    auto_sync_team_profiles: false,
    session_triage: true,
    guard_default_severity: "advisory",
    notifications: { sentinel: false, staleness_alerts: false },
    setup_completed_at: "2026-05-28T00:00:00Z"
  }' > "$USER_ROOT/preferences.json"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

@test "triage is silent when session_triage=false" {
  jq '.session_triage = false' "$USER_ROOT/preferences.json" > "$USER_ROOT/preferences.json.tmp" \
    && mv "$USER_ROOT/preferences.json.tmp" "$USER_ROOT/preferences.json"
  run bash "$REPO_ROOT/bin/session-triage.sh" --target "$REPO" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "triage exits silently in a non-git directory" {
  nogit="$TMP/nogit"
  mkdir -p "$nogit"
  run bash "$REPO_ROOT/bin/session-triage.sh" --target "$nogit" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "triage exits silently when preferences.json is missing" {
  rm -f "$USER_ROOT/preferences.json"
  run bash "$REPO_ROOT/bin/session-triage.sh" --target "$REPO" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-check rejects unknown --flow value" {
  run bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=bogus
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "session-start"
}

@test "session-check accepts --flow=session-start" {
  run bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=session-start
  # rc 0 either way; we just need it not to reject the flow value.
  [ "$status" -eq 0 ]
}

@test "fingerprint cache file is created on first session-start run that emits" {
  # First run in the empty repo with node-api profile should emit drift
  # (no hooks installed), which writes a fingerprint to cache.
  out1=$( cd "$REPO" && bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=session-start 2>/dev/null )
  if [ -n "$out1" ]; then
    # Cache file should now exist.
    fp_count=$(find "$USER_ROOT/cache" -maxdepth 1 -name "*.session-check" 2>/dev/null | wc -l | tr -d ' ')
    [ "$fp_count" -ge 1 ]
  fi
}

@test "fingerprint dedup: second run with same state is silent" {
  out1=$( cd "$REPO" && bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=session-start 2>/dev/null )
  [ -n "$out1" ]  # First run emits.
  out2=$( cd "$REPO" && bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=session-start 2>/dev/null )
  [ -z "$out2" ]  # Second run is deduped.
}

@test "non-session-start flows bypass fingerprint dedup" {
  out1=$( cd "$REPO" && bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=commit 2>/dev/null )
  out2=$( cd "$REPO" && bash "$REPO_ROOT/bin/session-check.sh" --user-root "$USER_ROOT" --flow=commit 2>/dev/null )
  # Both emit — commit flow must warn every time (about to mutate).
  [ -n "$out1" ]
  [ -n "$out2" ]
}
