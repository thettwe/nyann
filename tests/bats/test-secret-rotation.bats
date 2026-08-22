#!/usr/bin/env bats
# Secret-rotation reminders (bin/check-secret-rotation.sh) + the doctor
# LICENSES / SECRET ROTATION sibling sections. Ages come from committer
# dates (git log %ct), so fixtures commit with a pinned GIT_COMMITTER_DATE.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-rot.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m seed )
  CHECK="$REPO_ROOT/bin/check-secret-rotation.sh"
  PROFILE="$TMP/profile.json"
  jq -n '{security: {rotation_reminder: {enabled: true, files: [".env.example", "deploy/*.pem"], max_age_days: 90}}}' > "$PROFILE"
}

teardown() { rm -rf "$TMP"; }

# commit_dated <file> <iso-date> — commit a file with a pinned commit date.
commit_dated() {
  mkdir -p "$REPO/$(dirname "$1")"
  echo "content" > "$REPO/$1"
  ( cd "$REPO" && git add "$1" \
      && GIT_COMMITTER_DATE="$2" GIT_AUTHOR_DATE="$2" git commit -q -m "add $1" )
}

@test "disabled → enabled:false no-op, exit 0" {
  jq -n '{}' > "$PROFILE"
  run bash "$CHECK" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.enabled')" = "false" ]
}

@test "a file older than max_age_days is flagged with its age" {
  commit_dated .env.example "2026-01-01T00:00:00Z"
  run bash "$CHECK" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.summary.stale')" = "1" ]
  [ "$(echo "$output" | jq -r '.findings[0].file')" = ".env.example" ]
  age=$(echo "$output" | jq -r '.findings[0].age_days')
  [ "$age" -gt 90 ]
}

@test "a fresh file is not flagged but is counted as checked" {
  commit_dated .env.example "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run bash "$CHECK" --target "$REPO" --profile "$PROFILE"
  [ "$(echo "$output" | jq -r '.summary.stale')" = "0" ]
  [ "$(echo "$output" | jq -r '.summary.checked')" = "1" ]
}

@test "globs resolve tracked files (deploy/*.pem)" {
  commit_dated deploy/prod.pem "2026-01-01T00:00:00Z"
  run bash "$CHECK" --target "$REPO" --profile "$PROFILE"
  [ "$(echo "$output" | jq -r '.findings[0].file')" = "deploy/prod.pem" ]
}

@test "untracked files are skipped (the user's local .env is their business)" {
  echo "secret" > "$REPO/.env.example"
  run bash "$CHECK" --target "$REPO" --profile "$PROFILE"
  [ "$(echo "$output" | jq -r '.summary.checked')" = "0" ]
  [ "$(echo "$output" | jq -r '.summary.stale')" = "0" ]
}

@test "findings sort oldest-first and the report matches the schema surface" {
  commit_dated .env.example "2026-05-01T00:00:00Z"
  commit_dated deploy/old.pem "2026-01-01T00:00:00Z"
  run bash "$CHECK" --target "$REPO" --profile "$PROFILE"
  [ "$(echo "$output" | jq -r '.findings[0].file')" = "deploy/old.pem" ]
  [ "$(echo "$output" | jq -r 'keys - ["enabled","findings","max_age_days","summary"] | length')" = "0" ]
}

# --- doctor integration ------------------------------------------------------

# Install a full security-enabled user profile so doctor's load-profile
# resolves it via the overridden HOME.
install_sec_profile() {
  mkdir -p "$TMP/.claude/nyann/profiles"
  jq '.name = "sec-test"' "$REPO_ROOT/tests/fixtures/profiles/valid-security.json" \
    > "$TMP/.claude/nyann/profiles/sec-test.json"
}

@test "doctor --json carries license_scan + secret_rotation sibling fields" {
  install_sec_profile
  commit_dated .env.example "2026-01-01T00:00:00Z"
  out=$(env HOME="$TMP" bash "$REPO_ROOT/bin/doctor.sh" --target "$REPO" \
    --profile sec-test --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  echo "$out" | jq -e 'has("license_scan") and has("secret_rotation")' >/dev/null
  [ "$(echo "$out" | jq -r '.secret_rotation.summary.stale')" = "1" ]
}

@test "doctor text mode renders SECRET ROTATION and it never moves the exit code" {
  install_sec_profile
  commit_dated .env.example "2026-01-01T00:00:00Z"
  base_rc=0
  env HOME="$TMP" bash "$REPO_ROOT/bin/doctor.sh" --target "$REPO" \
    --profile default --gh "$TMP/no-such-gh" >/dev/null 2>&1 || base_rc=$?
  sec_out="$TMP/sec.out"; sec_rc=0
  env HOME="$TMP" bash "$REPO_ROOT/bin/doctor.sh" --target "$REPO" \
    --profile sec-test --gh "$TMP/no-such-gh" >"$sec_out" 2>&1 || sec_rc=$?
  grep -Fq "SECRET ROTATION:" "$sec_out"
  # Informational only: the security sections add no exit-code escalation
  # beyond what the repo's ordinary drift already produces.
  [ "$sec_rc" -eq "$base_rc" ]
}
