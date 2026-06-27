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
  CURL_KCONF="$TMP/curl.kconf"
  SENDMAIL_CAP="$TMP/sendmail.cap"
  export CURL_ARGV CURL_BODY CURL_KCONF SENDMAIL_CAP

  # Stub dir prepended to PATH so the fake curl/sendmail shadow the real ones
  # while every other tool (jq, md5sum, grep, …) still resolves normally. The
  # curl stub records argv (CURL_ARGV) AND the contents of any `-K <conf>`
  # config file (CURL_KCONF) so a test can prove the secret URL travels via the
  # 0600 config file and never appears on the command line.
  STUB="$TMP/stub"
  mkdir -p "$STUB"
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_ARGV"
prev=""
for a in "$@"; do
  [ "$prev" = "-K" ] && cat "$a" >> "$CURL_KCONF" 2>/dev/null
  prev="$a"
done
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
  # The URL curl received (via the 0600 -K config file) must equal the env
  # value, proving it was resolved from the environment and never stored in the
  # config. It must NOT appear on argv (where `ps` would expose the secret).
  grep -q "https://secret-from-env.test/only-here" "$CURL_KCONF"
  ! grep -q "https://secret-from-env.test/only-here" "$CURL_ARGV"
}

@test "slack/discord/webhook secret URL never reaches curl argv (only -K conf)" {
  # The webhook URL embeds the auth token; it must travel via the 0600 -K
  # config file, never on the command line where `ps`/`/proc` would leak it.
  for spec in \
    "slack|NYANN_SLACK_WEBHOOK|webhook_url_env|https://hooks.slack.test/T/B/seekret" \
    "discord|NYANN_DISCORD_WEBHOOK|webhook_url_env|https://discord.test/api/webhooks/1/seekret" \
    "webhook|NYANN_WEBHOOK_URL|url_env|https://example.test/seekret"; do
    IFS='|' read -r ch var key url <<<"$spec"
    : > "$CURL_ARGV"; : > "$CURL_KCONF"
    rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
    cfg=$(jq -nc --arg ch "$ch" --arg k "$key" --arg v "$var" '{($ch): {enabled:true, ($k): $v}}')
    export "$var=$url"
    printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" \
      --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
    # Secret on the -K conf, absent from argv; argv still carries -K.
    grep -q "$url" "$CURL_KCONF"
    ! grep -q "$url" "$CURL_ARGV"
    grep -q -- "-K" "$CURL_ARGV"
    unset "$var"
  done
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

@test "dedup: a soft-failed delivery is NOT marked and IS retried; a success is marked once" {
  export NYANN_WEBHOOK_URL="https://example.test/hook"
  local cfg='{"webhook":{"enabled":true,"url_env":"NYANN_WEBHOOK_URL"}}'

  # First — curl FAILS (exit 22). The notification must NOT be recorded, so a
  # SECOND run retries it: two curl attempts across two runs (no silent drop).
  failstub="$TMP/failcurl"; mkdir -p "$failstub"
  cat > "$failstub/curl" <<SH
#!/usr/bin/env bash
printf 'fail\n' >> "$TMP/fail.argv"
exit 22
SH
  chmod +x "$failstub/curl"
  printf '%s' "$BATCH" | PATH="$failstub:$PATH" bash "$DELIVER" --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  printf '%s' "$BATCH" | PATH="$failstub:$PATH" bash "$DELIVER" --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  [ "$(wc -l < "$TMP/fail.argv" | tr -d ' ')" -eq 2 ]

  # Then — curl SUCCEEDS (stub exit 0). The notification is delivered once.
  printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  [ "$(wc -l < "$CURL_ARGV" | tr -d ' ')" -eq 1 ]
  # Finally — now it IS marked, so a re-run does not resend (still one send).
  printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  [ "$(wc -l < "$CURL_ARGV" | tr -d ' ')" -eq 1 ]
}

@test "per-channel dedup: a failed channel retries while a succeeded sibling does not" {
  # Two channels for the SAME notification: slack confirms (exit 0), webhook
  # fails (exit 22). With per-channel markers, slack's id is recorded so it is
  # NOT re-sent next cycle, while webhook — left un-marked — IS retried. A
  # single shared marker would have let slack's success suppress webhook's retry.
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/ok"
  export NYANN_WEBHOOK_URL="https://example.test/down"
  local cfg='{"slack":{"enabled":true,"webhook_url_env":"NYANN_SLACK_WEBHOOK"},"webhook":{"enabled":true,"url_env":"NYANN_WEBHOOK_URL"}}'

  # Stub curl differentiates the two channels by request body: the generic
  # webhook POSTs a raw JSON array (`[...]`) — make THAT fail (exit 22); slack
  # POSTs `{text:...}` — let that succeed. Per-channel attempts are logged.
  stub2="$TMP/stub2"; mkdir -p "$stub2"
  cat > "$stub2/curl" <<SH
#!/usr/bin/env bash
body="\$(cat)"
case "\$body" in
  '['*) printf 'x\n' >> "$TMP/curl.fail.log"; exit 22 ;;
  *)    printf 'x\n' >> "$TMP/curl.ok.log";   exit 0  ;;
esac
SH
  chmod +x "$stub2/curl"

  # Cycle 1: slack OK (marked), webhook FAIL (not marked).
  printf '%s' "$BATCH" | PATH="$stub2:$PATH" bash "$DELIVER" --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  [ "$(wc -l < "$TMP/curl.ok.log" | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$TMP/curl.fail.log" | tr -d ' ')" -eq 1 ]

  # Cycle 2: slack is up to date → NOT re-sent; webhook was never marked →
  # retried. ok stays 1, fail grows to 2.
  printf '%s' "$BATCH" | PATH="$stub2:$PATH" bash "$DELIVER" --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  [ "$(wc -l < "$TMP/curl.ok.log" | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$TMP/curl.fail.log" | tr -d ' ')" -eq 2 ]

  # Per-channel markers: slack recorded, webhook absent (so it keeps retrying).
  shopt -s nullglob
  slack_marker=("$CACHE_DIR"/*.slack.delivered)
  webhook_marker=("$CACHE_DIR"/*.webhook.delivered)
  [ "${#slack_marker[@]}" -eq 1 ]
  [ "${#webhook_marker[@]}" -eq 0 ]
}

# --- Security: env-var-name RCE refusal --------------------------------------

@test "RCE: a url_env value with an injected command is REFUSED (no exec, no delivery)" {
  # `${!name}` would arithmetic-evaluate the array subscript and RUN the
  # command; the validation + printenv resolution must refuse it outright.
  sentinel_file="$TMP/SENTINEL_RCE"
  # Build the malicious env-var NAME as a LITERAL (single-quote the $(...) so
  # this test shell never executes it); only the path is expanded.
  mal='x[$(touch '"$sentinel_file"')]'
  cfg=$(jq -nc --arg e "$mal" '{webhook:{enabled:true, url_env:$e}}')
  out=$(printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" \
    --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" 2>&1)
  [ "$?" -eq 0 ]
  # The injected command never ran.
  [ ! -e "$sentinel_file" ]
  # And nothing was delivered (the channel was skipped as invalid).
  [ ! -s "$CURL_ARGV" ]
  echo "$out" | grep -qi "invalid env var name"
}

# --- Timeouts + email header injection ---------------------------------------

@test "curl delivery carries connection + max-time timeouts" {
  export NYANN_WEBHOOK_URL="https://example.test/hook"
  deliver_cfg '{"webhook":{"enabled":true,"url_env":"NYANN_WEBHOOK_URL"}}' >/dev/null
  grep -q -- "--max-time" "$CURL_ARGV"
  grep -q -- "--connect-timeout" "$CURL_ARGV"
}

@test "email.sh strips CR/LF from to/from (no RFC822 header injection)" {
  # A newline in email.to would otherwise inject an extra header. notify-deliver
  # passes the config value verbatim; email.sh must strip CR/LF before headers.
  cfg=$(jq -nc '{email:{enabled:true, to:"ops@team.test\nBcc: evil@x.test", from:"nyann@team.test"}}')
  printf '%s' "$BATCH" | PATH="$STUB:$PATH" bash "$DELIVER" \
    --repo o/r --config "$cfg" --cache-dir "$CACHE_DIR" >/dev/null 2>&1
  [ -s "$SENDMAIL_CAP" ]
  # No line STARTS with Bcc: — the injected text was folded into the To line.
  ! grep -q '^Bcc:' "$SENDMAIL_CAP"
  grep -q '^To: ops@team.test' "$SENDMAIL_CAP"
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
