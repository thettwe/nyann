#!/usr/bin/env bats
# CI sentinel — focuses on the non-network parts: notification queue
# handling, --stop semantics, schema validation. Real gh polling is mocked.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-sentinel.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  STATE_DIR="$TMP/state"
  NOTIF_DIR="$TMP/notifs"
  mkdir -p "$STATE_DIR" "$NOTIF_DIR"
}

teardown() { rm -rf "$TMP"; }

# Build a PATH dir that mirrors every tool on the current PATH EXCEPT gh, so
# "gh is missing" can be simulated even on runners that ship gh in /usr/bin
# alongside coreutils (where `PATH=/usr/bin:/bin` would NOT hide it).
nogh_path() {
  local dir="$TMP/nogh" d exe b
  mkdir -p "$dir"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for exe in "$d"/*; do
      [ -x "$exe" ] || continue
      b="$(basename "$exe")"
      [ "$b" = gh ] && continue
      [ -e "$dir/$b" ] || ln -s "$exe" "$dir/$b" 2>/dev/null || true
    done
  done
  printf '%s' "$dir"
}

@test "soft-skips with helpful message when gh is missing" {
  # Run with a PATH that genuinely lacks gh (robust on GitHub runners).
  ngh="$(nogh_path)"
  out=$( PATH="$ngh" bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo o/r --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" 2>&1 || true )
  echo "$out" | grep -q "gh CLI not installed"
}

@test "--stop is a noop when no pid file exists" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo o/r --stop --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
}

@test "--repo is required" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
}

@test "--pr rejects a non-integer value" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo o/r --pr abc --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must be a positive integer"
}

@test "--pr accepts a positive integer (soft-skips when gh missing)" {
  ngh="$(nogh_path)"
  run bash -c "PATH='$ngh' bash '$REPO_ROOT/bin/ci-sentinel.sh' --repo o/r --pr 42 --state-dir '$STATE_DIR' --notif-dir '$NOTIF_DIR'"
  [ "$status" -eq 0 ]
}

# --- --daemon-loop (v1.13.0 P8) ---------------------------------------------
# These exercise the supervised loop with a SHORT --max-runtime so it
# self-terminates in a couple of seconds — never a real long-running daemon.

@test "--daemon-loop rejects a non-numeric --interval" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --daemon-loop --repo o/r --interval abc --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "interval"
}

@test "--daemon-loop rejects a non-numeric --max-runtime" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --daemon-loop --repo o/r --max-runtime abc --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "max-runtime"
}

@test "--daemon-loop rejects an unknown --supervisor" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --daemon-loop --repo o/r --supervisor cron --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "supervisor"
}

@test "--daemon-loop self-terminates at --max-runtime and reaps its state" {
  # Mock gh returning no open PRs so each pass is a cheap no-op. With a 2s
  # cap the loop exits cleanly almost immediately — bounded, not long-running.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in pr) echo "" ; exit 0 ;; esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  hash=$(printf '%s' "o/r" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  PATH="$TMP/mock:$PATH" run bash "$REPO_ROOT/bin/ci-sentinel.sh" --daemon-loop \
    --repo o/r --interval 1 --max-runtime 2 \
    --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "max-runtime"
  # Clean exit reaps the pid file + daemon liveness block.
  [ ! -f "$STATE_DIR/${hash}.sentinel.pid" ]
  [ ! -f "$STATE_DIR/${hash}.sentinel.daemon.json" ]
}

@test "--daemon-loop refuses to start a second daemon for the same repo" {
  # Pre-seed a pid file pointing at a live *ci-sentinel*-looking process so
  # the single-instance guard fires. Use a stub ps to make the cmdline match.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in pr) echo "" ; exit 0 ;; esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  cat > "$TMP/mock/ps" <<'SH'
#!/bin/sh
echo "bash bin/ci-sentinel.sh --daemon-loop --repo o/r"
SH
  chmod +x "$TMP/mock/ps"
  hash=$(printf '%s' "o/r" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  echo $$ > "$STATE_DIR/${hash}.sentinel.pid"   # live pid = this bats process.
  PATH="$TMP/mock:$PATH" run bash "$REPO_ROOT/bin/ci-sentinel.sh" --daemon-loop \
    --repo o/r --interval 1 --max-runtime 2 \
    --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already running"
  # The pre-existing pid file (pointing at us) must NOT have been reaped.
  [ -f "$STATE_DIR/${hash}.sentinel.pid" ]
  [ "$(cat "$STATE_DIR/${hash}.sentinel.pid")" = "$$" ]
}

@test "read-notifications returns [] when queue file missing" {
  out=$(bash "$REPO_ROOT/bin/read-notifications.sh" --repo o/r --notif-dir "$NOTIF_DIR")
  echo "$out" | jq -e '. == []'
}

@test "read-notifications returns queued entries then truncates" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  notif="$NOTIF_DIR/${hash}.jsonl"
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"warning", message:"PR #42: CI failed", context:{pr:42}}' > "$notif"
  jq -n '{timestamp:"2026-05-28T00:00:05Z", source:"sentinel", severity:"info",    message:"PR #43: approved",  context:{pr:43}}' >> "$notif"
  out=$(bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$repo" --notif-dir "$NOTIF_DIR")
  count=$(echo "$out" | jq 'length')
  [ "$count" -eq 2 ]
  # File truncated.
  [ ! -s "$notif" ]
}

@test "read-notifications preserves a corrupt queue to .corrupt.* and returns []" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  notif="$NOTIF_DIR/${hash}.jsonl"
  # One valid line followed by a truncated/partial line — what a crashed
  # writer leaves behind. `jq -s` fails on this, so the reader must NOT rm.
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"info", message:"ok", context:{}}' > "$notif"
  printf '{"timestamp":"2026-05-28T00:00:05Z","source":"sentinel","sever' >> "$notif"
  out=$(bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$repo" --notif-dir "$NOTIF_DIR" 2>/dev/null)
  echo "$out" | jq -e '. == []'
  # Data preserved, not deleted: a .corrupt.* sibling exists with content.
  shopt -s nullglob
  corrupt=("$NOTIF_DIR/${hash}.jsonl.corrupt".*)
  [ "${#corrupt[@]}" -eq 1 ]
  [ -s "${corrupt[0]}" ]
  # The valid first line survived intact (jq emits pretty-printed objects,
  # so match on the value rather than a packed key:value pair).
  grep -q '"ok"' "${corrupt[0]}"
}

@test "concurrent append during read is not lost (shared lock)" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  notif="$NOTIF_DIR/${hash}.jsonl"
  lock="${notif}.lock"
  # Pre-acquire the shared lock by hand (same mkdir-based scheme the lib
  # uses), seed the queue, then start a reader. The reader must block on
  # the lock; while it's blocked we append a second entry. On release the
  # reader sees BOTH — the append is not dropped into a mv'd-away inode.
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"warning", message:"first", context:{}}' > "$notif"
  mkdir "$lock"
  bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$repo" --notif-dir "$NOTIF_DIR" > "$TMP/read.out" 2>/dev/null &
  reader_pid=$!
  # Give the reader time to reach (and block on) the lock.
  sleep 0.5
  jq -n '{timestamp:"2026-05-28T00:00:01Z", source:"sentinel", severity:"info", message:"second", context:{}}' >> "$notif"
  rmdir "$lock"
  wait "$reader_pid"
  out=$(cat "$TMP/read.out")
  [ "$(echo "$out" | jq 'length')" -eq 2 ]
  echo "$out" | jq -e 'map(.message) == ["first","second"]'
}

@test "read-notifications --peek leaves the file intact" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  notif="$NOTIF_DIR/${hash}.jsonl"
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"info", message:"x", context:{}}' > "$notif"
  before=$(wc -c < "$notif")
  bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$repo" --notif-dir "$NOTIF_DIR" --peek > /dev/null
  after=$(wc -c < "$notif")
  [ "$before" -eq "$after" ]
}

@test "Notification JSON validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"warning", message:"x", context:{pr:1}}' > "$TMP/n.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/notification.schema.json" "$TMP/n.json"
}

@test "SentinelState JSON validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{repo:"o/r", pr_number:42, base_branch:"main", head_branch:"feature/x", last_poll_at:"2026-05-28T00:00:00Z", checks_status:"pending", review_status:"no-reviews", merged:false}' > "$TMP/s.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/sentinel-state.schema.json" "$TMP/s.json"
}

# --- P9 delivery wiring (v1.13.0) -------------------------------------------
# End-to-end: a one-shot poll must fan QUEUED notifications out to a configured
# delivery channel via notify-deliver.sh. Mirrors the INC-1 lesson — wire-level
# integrations need an e2e test, not just unit coverage of notify-deliver.

@test "one-shot poll delivers queued notifications to a configured channel" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  # Seed an undelivered notification.
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"warning", message:"PR #42: CI failed", context:{pr:42}}' \
    > "$NOTIF_DIR/${hash}.jsonl"

  # Configure a generic webhook channel; secret URL lives only in the env var.
  USER_ROOT="$TMP/userroot"; mkdir -p "$USER_ROOT"
  jq -n '{schemaVersion:3, notifications:{delivery:{webhook:{enabled:true, url_env:"NYANN_TEST_WEBHOOK"}}}}' \
    > "$USER_ROOT/preferences.json"

  # Mock gh (no open PRs → one-shot hits the no-PR flush path) and curl
  # (records the delivery so we can assert it fired).
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in pr) echo "" ; exit 0 ;; esac
exit 0
SH
  cat > "$TMP/mock/curl" <<SH
#!/bin/sh
echo "called \$*" >> "$TMP/curl.calls"
exit 0
SH
  chmod +x "$TMP/mock/gh" "$TMP/mock/curl"

  PATH="$TMP/mock:$PATH" NYANN_USER_ROOT="$USER_ROOT" NYANN_TEST_WEBHOOK="https://example.test/hook" \
    run bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo "$repo" \
      --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
  # Delivery fired: curl was invoked at least once.
  [ -f "$TMP/curl.calls" ]
  # Peek-based delivery does NOT truncate the queue — session-start still sees it.
  [ -s "$NOTIF_DIR/${hash}.jsonl" ]
}

@test "one-shot poll is a silent no-op when no delivery channel is configured" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"info", message:"x", context:{}}' \
    > "$NOTIF_DIR/${hash}.jsonl"
  USER_ROOT="$TMP/userroot"; mkdir -p "$USER_ROOT"
  jq -n '{schemaVersion:3}' > "$USER_ROOT/preferences.json"   # no delivery block
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in pr) echo "" ; exit 0 ;; esac
exit 0
SH
  cat > "$TMP/mock/curl" <<SH
#!/bin/sh
echo "called" >> "$TMP/curl.calls"
exit 0
SH
  chmod +x "$TMP/mock/gh" "$TMP/mock/curl"
  PATH="$TMP/mock:$PATH" NYANN_USER_ROOT="$USER_ROOT" \
    run bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo "$repo" \
      --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
  # No channel configured → no network call.
  [ ! -f "$TMP/curl.calls" ]
}
