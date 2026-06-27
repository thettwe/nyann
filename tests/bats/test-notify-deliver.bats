#!/usr/bin/env bats
# notify-deliver.sh + bin/notify-channels/* — external notification delivery.
# Network is mocked: a fake `curl` (and `sendmail`) on PATH captures the
# request body/argv so payload shape, env-var resolution, dedup, and
# soft-skips can be asserted without sending anything.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-notify.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  CACHE_DIR="$TMP/cache"
  USER_ROOT="$TMP/user-root"
  mkdir -p "$CACHE_DIR" "$USER_ROOT"

  DELIVER="$REPO_ROOT/bin/notify-deliver.sh"
  SETTINGS="$REPO_ROOT/bin/settings.sh"

  # One notification; severity/message are asserted in payload-shape tests.
  BATCH='[{"timestamp":"2026-06-27T00:00:00Z","source":"sentinel","severity":"critical","message":"PR #42: CI failed","context":{"pr":42}}]'

  # Capture sinks for the mocks, read at runtime via the environment.
  CURL_ARGV="$TMP/curl.argv"
  CURL_BODY="$TMP/curl.body"
  SENDMAIL_CAP="$TMP/sendmail.cap"
  export CURL_ARGV CURL_BODY SENDMAIL_CAP

  # Stub dir prepended to PATH so the fake curl/sendmail shadow the real ones
  # while every other tool (jq, md5sum, grep, …) still resolves normally.
  STUB="$TMP/stub"
  mkdir -p "$STUB"
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_ARGV"
cat >> "$CURL_BODY"
printf '\n' >> "$CURL_BODY"
exit 0
SH
  cat > "$STUB/sendmail" <<'SH'
#!/usr/bin/env bash
cat >> "$SENDMAIL_CAP"
exit 0
SH
  chmod +x "$STUB/curl" "$STUB/sendmail"
}

teardown() { rm -rf "$TMP"; }

# Run notify-deliver with the stub PATH and a JSON --config; batch on stdin.
deliver_cfg() { # $1 = delivery config JSON
  printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" \
    --repo o/r --config "$1" --cache-dir "$CACHE_DIR" 2>&1
}

# Build a PATH that mirrors the real one EXCEPT curl, to simulate "curl
# missing" robustly even where curl lives next to coreutils.
nocurl_path() {
  local dir="$TMP/nocurl" d exe b
  mkdir -p "$dir"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for exe in "$d"/*; do
      [ -x "$exe" ] || continue
      b="$(basename "$exe")"
      [ "$b" = curl ] && continue
      [ -e "$dir/$b" ] || ln -s "$exe" "$dir/$b" 2>/dev/null || true
    done
  done
  printf '%s' "$dir"
}

# Write a v2 preferences.json (no delivery block) for settings.sh tests.
write_v2_prefs() {
  jq -n '{
    schemaVersion: 2,
    default_profile: "auto-detect",
    branching_strategy: "auto-detect",
    commit_format: "conventional-commits",
    gh_integration: true,
    documentation_storage: "local",
    auto_sync_team_profiles: false,
    session_triage: true,
    guard_default_severity: "advisory",
    notifications: { sentinel: true, staleness_alerts: true },
    setup_completed_at: "2026-06-01T00:00:00Z"
  }' > "$USER_ROOT/preferences.json"
}

# --- Channel payload shapes --------------------------------------------------

@test "slack delivers a {text: ...} incoming-webhook payload" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  out=$(deliver_cfg '{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"}}')
  [ "$?" -eq 0 ]
  jq -e '.text' "$CURL_BODY"
  jq -re '.text' "$CURL_BODY" | grep -q "PR #42: CI failed"
}

@test "discord delivers a {content: ...} webhook payload" {
  export NYANN_DISCORD_WEBHOOK="https://discord.test/api/webhooks/1/abc"
  out=$(deliver_cfg '{"discord":{"enabled":true,"webhook_url_env":"NYANN_DISCORD_WEBHOOK"}}')
  [ "$?" -eq 0 ]
  jq -e '.content' "$CURL_BODY"
  jq -re '.content' "$CURL_BODY" | grep -q "PR #42: CI failed"
}

@test "generic webhook POSTs the raw notification array" {
  export NYANN_WEBHOOK_URL="https://example.test/ingest"
  out=$(deliver_cfg '{"webhook":{"enabled":true,"url_env":"NYANN_WEBHOOK_URL"}}')
  [ "$?" -eq 0 ]
  jq -e 'type == "array"' "$CURL_BODY"
  jq -e '.[0].message == "PR #42: CI failed"' "$CURL_BODY"
}

@test "webhook URL is read from the env var, NOT from preferences" {
  # Preferences hold only the env-var NAME; the URL lives solely in the env.
  export NYANN_WEBHOOK_URL="https://secret-from-env.test/only-here"
  out=$(deliver_cfg '{"webhook":{"enabled":true,"url_env":"NYANN_WEBHOOK_URL"}}')
  [ "$?" -eq 0 ]
  # The target URL curl was invoked with must equal the env value, proving it
  # was resolved from the environment and never stored in the config.
  grep -q "https://secret-from-env.test/only-here" "$CURL_ARGV"
}

@test "email delivers via mocked sendmail with RFC822 headers" {
  out=$(deliver_cfg '{"email":{"enabled":true,"to":"ops@team.test","from":"nyann@team.test"}}')
  [ "$?" -eq 0 ]
  [ -s "$SENDMAIL_CAP" ]
  grep -q "^To: ops@team.test"   "$SENDMAIL_CAP"
  grep -q "^From: nyann@team.test" "$SENDMAIL_CAP"
  grep -q "^Subject: \[nyann\]"  "$SENDMAIL_CAP"
  grep -q "PR #42: CI failed"     "$SENDMAIL_CAP"
}

# --- Opt-in / soft-skip behavior ---------------------------------------------

@test "no channel configured is a silent no-op (no network)" {
  out=$(deliver_cfg '{}')
  [ "$?" -eq 0 ]
  [ ! -s "$CURL_BODY" ]
  [ ! -s "$CURL_ARGV" ]
}

@test "no preferences file and no --config is a no-op" {
  out=$(printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" \
    --repo o/r --user-root "$USER_ROOT" --cache-dir "$CACHE_DIR" 2>&1)
  [ "$?" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
}

@test "empty batch [] is a no-op even with a channel enabled" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  out=$(printf '%s' '[]' | PATH="$STUB:$PATH" bash "$DELIVER" \
    --repo o/r --config '{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"}}' \
    --cache-dir "$CACHE_DIR" 2>&1)
  [ "$?" -eq 0 ]
  [ ! -s "$CURL_ARGV" ]
}

@test "enabled channel with an unset env var skips with a warning, exit 0" {
  # NYANN_SLACK_WEBHOOK intentionally NOT exported.
  out=$(deliver_cfg '{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"}}')
  [ "$?" -eq 0 ]
  echo "$out" | grep -qi "unset"
  [ ! -s "$CURL_BODY" ]
}

@test "channel soft-skips when curl is missing, exit 0" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  ncp="$(nocurl_path)"
  out=$(printf '%s' "$BATCH" | PATH="$ncp" bash "$DELIVER" \
    --repo o/r --config '{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"}}' \
    --cache-dir "$CACHE_DIR" 2>&1)
  [ "$?" -eq 0 ]
  echo "$out" | grep -qi "curl not installed"
}

# --- Dedup -------------------------------------------------------------------

@test "dedup: the same notification is never delivered twice" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  local cfg='{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"}}'
  deliver_cfg "$cfg" >/dev/null
  deliver_cfg "$cfg" >/dev/null
  # Exactly one curl invocation across both runs.
  [ "$(wc -l < "$CURL_ARGV" | tr -d ' ')" -eq 1 ]
}

@test "dedup marker file is written under the cache dir" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  deliver_cfg '{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"}}' >/dev/null
  shopt -s nullglob
  markers=("$CACHE_DIR"/*.delivered)
  [ "${#markers[@]}" -eq 1 ]
  [ -s "${markers[0]}" ]
}

# --- Fan-out + prefs source --------------------------------------------------

@test "multiple enabled channels each receive the batch" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  export NYANN_DISCORD_WEBHOOK="https://discord.test/api/webhooks/1/abc"
  out=$(deliver_cfg '{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"},"discord":{"enabled":true,"webhook_url_env":"NYANN_DISCORD_WEBHOOK"}}')
  [ "$?" -eq 0 ]
  [ "$(wc -l < "$CURL_ARGV" | tr -d ' ')" -eq 2 ]
}

@test "delivery config is read from preferences.json when no --config given" {
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/T/B/xyz"
  jq -n '{
    schemaVersion: 3,
    default_profile: "auto-detect",
    notifications: {
      sentinel: true, staleness_alerts: true,
      delivery: { slack: { enabled: true, webhook_url_env: "NYANN_SLACK_WEBHOOK" } }
    }
  }' > "$USER_ROOT/preferences.json"
  out=$(printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" \
    --repo o/r --user-root "$USER_ROOT" --cache-dir "$CACHE_DIR" 2>&1)
  [ "$?" -eq 0 ]
  jq -e '.text' "$CURL_BODY"
}

# --- settings.sh security + upgrade ------------------------------------------

@test "settings REFUSES a literal URL for a delivery env-name key" {
  write_v2_prefs
  run bash "$SETTINGS" --user-root "$USER_ROOT" \
    --set notifications.delivery.slack.webhook_url_env "https://hooks.slack.com/services/AAA/BBB/CCC"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "refusing to store a literal URL"
  # File untouched — still v2, no delivery block.
  [ "$(jq -r '.schemaVersion' "$USER_ROOT/preferences.json")" = "2" ]
  jq -e '.notifications.delivery == null' "$USER_ROOT/preferences.json"
}

@test "settings REFUSES a literal URL for email smtp_env too" {
  write_v2_prefs
  run bash "$SETTINGS" --user-root "$USER_ROOT" \
    --set notifications.delivery.email.smtp_env "https://relay.example.com"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "refusing to store a literal URL"
}

@test "settings accepts an env-var NAME and upgrades the file to schemaVersion 3" {
  write_v2_prefs
  run bash "$SETTINGS" --user-root "$USER_ROOT" \
    --set notifications.delivery.slack.webhook_url_env NYANN_SLACK_WEBHOOK
  [ "$status" -eq 0 ]
  prefs="$USER_ROOT/preferences.json"
  [ "$(jq -r '.schemaVersion' "$prefs")" = "3" ]
  jq -e '.notifications.delivery.slack.webhook_url_env == "NYANN_SLACK_WEBHOOK"' "$prefs"
  # Sibling notification toggles are preserved across the upgrade.
  jq -e '.notifications.sentinel == true' "$prefs"
}

@test "settings rejects an env name that is not a valid identifier" {
  write_v2_prefs
  run bash "$SETTINGS" --user-root "$USER_ROOT" \
    --set notifications.delivery.webhook.url_env "not a name"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "invalid env var name"
}

# --- schema validation -------------------------------------------------------

@test "delivery config validates against notification-delivery-config schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{
    slack:   { enabled: true,  webhook_url_env: "NYANN_SLACK_WEBHOOK" },
    discord: { enabled: false, webhook_url_env: "NYANN_DISCORD_WEBHOOK" },
    webhook: { enabled: false, url_env: "NYANN_WEBHOOK_URL" },
    email:   { enabled: true,  to: "a@b.test", from: "c@d.test", smtp_env: "NYANN_SMTP_URL" }
  }' > "$TMP/cfg.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/notification-delivery-config.schema.json" "$TMP/cfg.json"
}

@test "preferences with a delivery block validates against the preferences schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{
    schemaVersion: 3,
    default_profile: "auto-detect",
    notifications: {
      sentinel: true, staleness_alerts: true,
      delivery: { slack: { enabled: true, webhook_url_env: "NYANN_SLACK_WEBHOOK" } }
    }
  }' > "$TMP/prefs.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/preferences.schema.json" "$TMP/prefs.json"
}
