#!/usr/bin/env bats
# bin/sentinel-daemon.sh — lifecycle manager for the backgrounded CI sentinel
# (v1.13.0 P8). All supervisors (launchctl / systemctl / nohup) and the
# ci-sentinel loop itself are STUBBED on PATH — NO test ever spawns a real
# long-running daemon. We assert filesystem + argument side effects (pid
# file, plist/unit written, .calls logs, stdout), never real process state.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/bin/sentinel-daemon.sh"
  TMP="$(mktemp -d -t nyann-daemon.XXXXXX)"; TMP="$(cd "$TMP" && pwd -P)"
  STATE_DIR="$TMP/state"
  NOTIF_DIR="$TMP/notifs"
  LOG_DIR="$TMP/logs"
  MOCK="$TMP/mock"
  # Isolate HOME so the script's default ~/Library/LaunchAgents and
  # ~/.config/systemd/user paths land inside the sandbox.
  export HOME="$TMP/home"
  mkdir -p "$STATE_DIR" "$NOTIF_DIR" "$LOG_DIR" "$MOCK" "$HOME"
  REPO="o/r"
  HASH=$(printf '%s' "$REPO" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12)
  PID_FILE="$STATE_DIR/${HASH}.sentinel.pid"
  DAEMON_FILE="$STATE_DIR/${HASH}.sentinel.daemon.json"
  # Aggregate daemon (v1.13.0 P10) uses FIXED file names — there is one per user.
  WL="$TMP/watch-list.json"
  AGG_PID_FILE="$STATE_DIR/aggregate.sentinel.pid"
  AGG_DAEMON_FILE="$STATE_DIR/aggregate.sentinel.daemon.json"
}

teardown() { rm -rf "$TMP"; }

# Write a stub executable that logs its args and exits with the given code.
make_stub() { # $1=name $2=exit-code(default 0)
  cat > "$MOCK/$1" <<SH
#!/bin/sh
echo "\$@" >> "$TMP/$1.calls"
exit ${2:-0}
SH
  chmod +x "$MOCK/$1"
}

# Common args.
sd() { # verb + extra args; PATH-prefixes the mock dir
  PATH="$MOCK:$PATH" run bash "$SCRIPT" "$@" \
    --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --log-dir "$LOG_DIR"
}

# Aggregate variant: appends --aggregate + a sandboxed --watch-list.
sda() { # verb + extra args; PATH-prefixes the mock dir
  PATH="$MOCK:$PATH" run bash "$SCRIPT" "$@" --aggregate \
    --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --log-dir "$LOG_DIR" --watch-list "$WL"
}

# spawn_nohup is intentionally ASYNC (nohup ... & disown) so start never
# blocks the foreground. Its stub's .calls log therefore lands a beat after
# the script returns — poll for it with a short bounded wait rather than
# asserting synchronously (which would be racy).
wait_for_calls() { # $1=path  $2=max-tenths(default 30 → 3s)
  local f="$1" max="${2:-30}" i=0
  while (( i < max )); do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$(( i + 1 ))
  done
  [ -s "$f" ]
}

# --- verb dispatch -----------------------------------------------------------

@test "missing verb dies with a helpful message" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "missing verb"
}

@test "unknown verb dies" {
  run bash "$SCRIPT" frobnicate --repo "$REPO"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "unknown verb"
}

@test "start requires --repo" {
  run bash "$SCRIPT" start --state-dir "$STATE_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "repo"
}

# --- supervisor selection by platform ---------------------------------------

@test "start writes a launchd plist + bootstraps when supervisor=launchd" {
  make_stub launchctl 0
  sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  # The plist was generated under the isolated HOME.
  [ -f "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist" ]
  # launchctl was invoked to load/bootstrap it.
  [ -f "$TMP/launchctl.calls" ]
  grep -Eq "bootstrap|load" "$TMP/launchctl.calls"
  # The rendered plist points at the real sentinel binary, this repo, and
  # carries the orphan-backstop max-runtime.
  grep -q "ci-sentinel.sh" "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  grep -q "$REPO" "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  grep -q "max-runtime" "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  echo "$output" | grep -qi "supervisor: launchd"
}

@test "start writes a systemd user unit + starts it when supervisor=systemd" {
  make_stub systemctl 0
  sd start --repo "$REPO" --supervisor systemd
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/systemd/user/nyann-sentinel.service" ]
  [ -f "$TMP/systemctl.calls" ]
  grep -q "start" "$TMP/systemctl.calls"
  grep -q "ci-sentinel.sh" "$HOME/.config/systemd/user/nyann-sentinel.service"
  grep -q "$REPO" "$HOME/.config/systemd/user/nyann-sentinel.service"
  echo "$output" | grep -qi "supervisor: systemd"
}

@test "auto-selects launchd on Darwin when launchctl present (no override)" {
  # Stub uname → Darwin and launchctl present; systemctl absent forces launchd.
  make_stub launchctl 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
case "$1" in -s) echo Darwin ;; *) echo "Darwin x 1" ;; esac
SH
  chmod +x "$MOCK/uname"
  sd start --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist" ]
  echo "$output" | grep -qi "supervisor: launchd"
}

@test "auto-selects systemd on Linux when systemctl present (no override)" {
  make_stub systemctl 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
case "$1" in -s) echo Linux ;; *) echo "Linux x 1" ;; esac
SH
  chmod +x "$MOCK/uname"
  sd start --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/systemd/user/nyann-sentinel.service" ]
  echo "$output" | grep -qi "supervisor: systemd"
}

# --- nohup fallback ----------------------------------------------------------

@test "falls back to nohup when neither launchctl nor systemctl is present" {
  # Build a PATH that has the mock dir (with nohup stub) but NO launchctl /
  # systemctl. uname stub returns an unknown OS so neither branch is taken.
  make_stub nohup 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
echo BeOS
SH
  chmod +x "$MOCK/uname"
  sd start --repo "$REPO"
  [ "$status" -eq 0 ]
  # nohup was invoked to spawn the loop, and the args reference ci-sentinel.
  wait_for_calls "$TMP/nohup.calls"
  grep -q "ci-sentinel" "$TMP/nohup.calls"
  grep -q -- "--daemon-loop" "$TMP/nohup.calls"
  echo "$output" | grep -qi "supervisor: nohup"
  # No supervisor unit files written in the nohup path.
  [ ! -f "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist" ]
  [ ! -f "$HOME/.config/systemd/user/nyann-sentinel.service" ]
}

@test "supervisor LOAD failure soft-falls-back to nohup (never blocks)" {
  # launchctl present but failing (exit 1) → start must NOT abort; it spawns
  # via nohup instead.
  make_stub launchctl 1
  make_stub nohup 0
  sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  wait_for_calls "$TMP/nohup.calls"
  grep -q "ci-sentinel" "$TMP/nohup.calls"
  echo "$output" | grep -qi "supervisor: nohup"
}

# --- idempotent start --------------------------------------------------------

@test "idempotent start: a live daemon is not duplicated" {
  # Hand-write a pid file pointing at THIS bats process, and stub ps so the
  # cmdline check matches a sentinel — i.e. a live daemon already owns the repo.
  echo $$ > "$PID_FILE"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/ci-sentinel.sh --daemon-loop --repo o/r"
SH
  chmod +x "$MOCK/ps"
  make_stub launchctl 0
  make_stub nohup 0
  sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already running"
  # Neither supervisor nor nohup was invoked the second time.
  [ ! -f "$TMP/nohup.calls" ]
  [ ! -f "$TMP/launchctl.calls" ]
}

@test "start reclaims a STALE pid file (dead process) and launches" {
  # Pid file points at a process that ps reports as NOT a sentinel.
  echo 999999 > "$PID_FILE"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "some-unrelated-process"
SH
  chmod +x "$MOCK/ps"
  make_stub nohup 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
echo Unknown
SH
  chmod +x "$MOCK/uname"
  sd start --repo "$REPO"
  [ "$status" -eq 0 ]
  # It proceeded to spawn (stale pid did not block it).
  wait_for_calls "$TMP/nohup.calls"
}

# --- stop reaps pid + tears down supervisor ---------------------------------

@test "stop reaps the pid file and the daemon block" {
  echo 999999 > "$PID_FILE"
  printf '{"repo":"%s","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' "$REPO" > "$DAEMON_FILE"
  # Stub kill + ps so the underlying ci-sentinel --stop does not signal a
  # real process.
  make_stub kill 0
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/ci-sentinel.sh --daemon-loop"
SH
  chmod +x "$MOCK/ps"
  sd stop --repo "$REPO"
  [ "$status" -eq 0 ]
  [ ! -f "$PID_FILE" ]
  [ ! -f "$DAEMON_FILE" ]
  echo "$output" | grep -qi "stopped"
}

@test "stop tears down the recorded launchd supervisor unit" {
  printf '{"repo":"%s","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"launchd"}}\n' "$REPO" > "$DAEMON_FILE"
  mkdir -p "$HOME/Library/LaunchAgents"
  touch "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  make_stub launchctl 0
  sd stop --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$TMP/launchctl.calls" ]
  grep -Eq "bootout|unload" "$TMP/launchctl.calls"
  # Unit file removed.
  [ ! -f "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist" ]
}

@test "stop is a clean noop when nothing is running" {
  sd stop --repo "$REPO"
  [ "$status" -eq 0 ]
}

# --- status reports state ----------------------------------------------------

@test "status reports running when pid points at a live sentinel" {
  echo $$ > "$PID_FILE"
  printf '{"repo":"%s","daemon":{"pid":%s,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' "$REPO" "$$" > "$DAEMON_FILE"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/ci-sentinel.sh --daemon-loop --repo o/r"
SH
  chmod +x "$MOCK/ps"
  sd status --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "running"
  echo "$output" | grep -qi "nohup"
}

@test "status flags a STALE daemon (pid file present, process dead)" {
  echo 999999 > "$PID_FILE"
  printf '{"repo":"%s","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' "$REPO" > "$DAEMON_FILE"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  sd status --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "stale"
}

@test "status reports no daemon when none exists" {
  sd status --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "no daemon"
}

@test "status --json emits a well-formed object with watched PRs" {
  echo $$ > "$PID_FILE"
  printf '{"repo":"%s","daemon":{"pid":%s,"started_at":"2026-06-07T00:00:00Z","supervisor":"systemd"}}\n' "$REPO" "$$" > "$DAEMON_FILE"
  # Seed a per-PR state file so watched_prs is populated.
  printf '{"repo":"%s","pr_number":42,"last_poll_at":"2026-06-07T00:00:00Z","checks_status":"pending","review_status":"no-reviews"}\n' "$REPO" > "$STATE_DIR/${HASH}.pr42.sentinel.json"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/ci-sentinel.sh --daemon-loop"
SH
  chmod +x "$MOCK/ps"
  PATH="$MOCK:$PATH" out=$(bash "$SCRIPT" status --repo "$REPO" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --log-dir "$LOG_DIR" --json)
  echo "$out" | jq -e '.running == true' >/dev/null
  echo "$out" | jq -e '.supervisor == "systemd"' >/dev/null
  echo "$out" | jq -e '.watched_prs == [42]' >/dev/null
}

# --- restart -----------------------------------------------------------------

@test "restart stops then starts (pid replaced, supervisor re-invoked)" {
  # Pre-existing daemon block recorded as nohup; stub kill/ps for the stop arm.
  echo 999999 > "$PID_FILE"
  printf '{"repo":"%s","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' "$REPO" > "$DAEMON_FILE"
  make_stub kill 0
  make_stub nohup 0
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
# After stop, the (stale) pid is gone; report a non-sentinel so start does
# not think a live daemon already owns the repo.
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
echo Unknown
SH
  chmod +x "$MOCK/uname"
  sd restart --repo "$REPO"
  [ "$status" -eq 0 ]
  # Stop reaped the old block; start re-spawned via nohup.
  wait_for_calls "$TMP/nohup.calls"
  grep -q "ci-sentinel" "$TMP/nohup.calls"
}

# --- report (doctor surface) -------------------------------------------------

@test "report emits an array of daemons across repos" {
  printf '{"repo":"a/b","daemon":{"pid":111,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' > "$STATE_DIR/aaaaaaaaaaaa.sentinel.daemon.json"
  printf '{"repo":"c/d","daemon":{"pid":222,"started_at":"2026-06-07T00:00:00Z","supervisor":"systemd"}}\n' > "$STATE_DIR/bbbbbbbbbbbb.sentinel.daemon.json"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  PATH="$MOCK:$PATH" out=$(bash "$SCRIPT" report --state-dir "$STATE_DIR" --json)
  [ "$(echo "$out" | jq 'length')" -eq 2 ]
  # Both are stale (ps reports non-sentinel) but still listed — never invisible.
  echo "$out" | jq -e 'all(.[]; .stale == true)' >/dev/null
  echo "$out" | jq -e 'map(.repo) | sort == ["a/b","c/d"]' >/dev/null
}

@test "report is an empty array when no daemons exist" {
  out=$(bash "$SCRIPT" report --state-dir "$STATE_DIR" --json)
  echo "$out" | jq -e '. == []' >/dev/null
}

# --- crash does not corrupt the notification queue ---------------------------

@test "a daemon crash does not corrupt the notification queue" {
  # Seed the queue with valid NDJSON the reader can drain. Then simulate a
  # crashed daemon: the pid file points at a dead process. stop reaps it.
  # The queue must survive intact and still be drainable by read-notifications.
  notif="$NOTIF_DIR/${HASH}.jsonl"
  # Compact NDJSON, exactly as append_notification accumulates it.
  jq -cn '{timestamp:"2026-06-07T00:00:00Z", source:"sentinel", severity:"warning", message:"PR #42: CI failed", context:{pr:42}}' > "$notif"
  jq -cn '{timestamp:"2026-06-07T00:00:05Z", source:"sentinel", severity:"info", message:"PR #43: approved", context:{pr:43}}' >> "$notif"
  bytes_before=$(wc -c < "$notif")
  echo 999999 > "$PID_FILE"   # crashed daemon left a stale pid.
  make_stub kill 0
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  sd stop --repo "$REPO"
  [ "$status" -eq 0 ]
  # Queue untouched by stop — byte-identical, no corruption.
  [ "$(wc -c < "$notif")" -eq "$bytes_before" ]
  # And the real reader still drains it cleanly into 2 entries.
  out=$(bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$REPO" --notif-dir "$NOTIF_DIR")
  [ "$(echo "$out" | jq 'length')" -eq 2 ]
  # No .corrupt.* sibling was created.
  shopt -s nullglob
  corrupt=("$NOTIF_DIR/${HASH}.jsonl.corrupt".*)
  [ "${#corrupt[@]}" -eq 0 ]
}

# --- aggregate daemon (v1.13.0 P10) -----------------------------------------
# --aggregate retargets start|stop|status|restart at the single per-user
# multi-repo aggregate daemon (sentinel-aggregate.sh), which uses fixed
# aggregate.sentinel.* file names. The supervisors stay STUBBED — no test ever
# spawns a real daemon.

@test "start --aggregate falls back to nohup and launches sentinel-aggregate --daemon-loop" {
  make_stub nohup 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
echo BeOS
SH
  chmod +x "$MOCK/uname"
  sda start
  [ "$status" -eq 0 ]
  # nohup was invoked to spawn the AGGREGATE loop, with the watch-list wired.
  wait_for_calls "$TMP/nohup.calls"
  grep -q "sentinel-aggregate" "$TMP/nohup.calls"
  grep -q -- "--daemon-loop" "$TMP/nohup.calls"
  grep -q -- "--watch-list" "$TMP/nohup.calls"
  echo "$output" | grep -qi "aggregate daemon started"
  echo "$output" | grep -qi "supervisor: nohup"
  # No aggregate supervisor unit files written in the nohup path.
  [ ! -f "$HOME/Library/LaunchAgents/com.nyann.sentinel-aggregate.plist" ]
  [ ! -f "$HOME/.config/systemd/user/nyann-sentinel-aggregate.service" ]
}

@test "start --aggregate writes the aggregate launchd plist + bootstraps (supervisor=launchd)" {
  make_stub launchctl 0
  sda start --supervisor launchd
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.nyann.sentinel-aggregate.plist"
  [ -f "$plist" ]
  [ -f "$TMP/launchctl.calls" ]
  grep -Eq "bootstrap|load" "$TMP/launchctl.calls"
  # Rendered plist points at the aggregate binary + watch-list, carries the
  # orphan-backstop max-runtime, and has NO leftover ${...} placeholders.
  grep -q "sentinel-aggregate.sh" "$plist"
  grep -q "$WL" "$plist"
  grep -q "max-runtime" "$plist"
  ! grep -q '\${' "$plist"
  echo "$output" | grep -qi "supervisor: launchd"
  # The per-repo plist is NOT touched by the aggregate path.
  [ ! -f "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist" ]
}

@test "status --aggregate reports running (pid_is_live matches a sentinel-aggregate cmdline) then stale" {
  echo $$ > "$AGG_PID_FILE"
  printf '{"repo":"(aggregate)","pr_number":0,"last_poll_at":"2026-06-07T00:00:00Z","checks_status":"unknown","review_status":"unknown","daemon":{"pid":%s,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' "$$" > "$AGG_DAEMON_FILE"
  printf '[{"repo":"o/a"},{"repo":"o/b"}]\n' > "$WL"
  # ps reports a sentinel-aggregate-looking cmdline → generalized pid_is_live
  # must classify it RUNNING (it would be falsely STALE without the fix).
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/sentinel-aggregate.sh --daemon-loop"
SH
  chmod +x "$MOCK/ps"
  sda status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "aggregate daemon running"
  # Watched repos come from the watch-list, not per-PR state files.
  echo "$output" | grep -q "o/a"
  echo "$output" | grep -q "o/b"
  # Now make the process look dead → STALE.
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  sda status
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "stale"
}

@test "status --aggregate --json lists watched repos" {
  echo $$ > "$AGG_PID_FILE"
  printf '{"repo":"(aggregate)","pr_number":0,"last_poll_at":"2026-06-07T00:00:00Z","checks_status":"unknown","review_status":"unknown","daemon":{"pid":%s,"started_at":"2026-06-07T00:00:00Z","supervisor":"systemd"}}\n' "$$" > "$AGG_DAEMON_FILE"
  printf '[{"repo":"o/a"},{"repo":"o/b","prs":[5]}]\n' > "$WL"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/sentinel-aggregate.sh --daemon-loop"
SH
  chmod +x "$MOCK/ps"
  PATH="$MOCK:$PATH" out=$(bash "$SCRIPT" status --aggregate --state-dir "$STATE_DIR" \
    --notif-dir "$NOTIF_DIR" --log-dir "$LOG_DIR" --watch-list "$WL" --json)
  echo "$out" | jq -e '.aggregate == true'
  echo "$out" | jq -e '.running == true'
  echo "$out" | jq -e '.supervisor == "systemd"'
  echo "$out" | jq -e '.watched_repos | sort == ["o/a","o/b"]'
}

@test "stop --aggregate reaps the aggregate pid + block" {
  echo 999999 > "$AGG_PID_FILE"
  printf '{"repo":"(aggregate)","pr_number":0,"last_poll_at":"2026-06-07T00:00:00Z","checks_status":"unknown","review_status":"unknown","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' > "$AGG_DAEMON_FILE"
  make_stub kill 0
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/sentinel-aggregate.sh --daemon-loop"
SH
  chmod +x "$MOCK/ps"
  sda stop
  [ "$status" -eq 0 ]
  [ ! -f "$AGG_PID_FILE" ]
  [ ! -f "$AGG_DAEMON_FILE" ]
  echo "$output" | grep -qi "aggregate daemon stopped"
}

@test "stop --aggregate is a clean noop when nothing is running" {
  sda stop
  [ "$status" -eq 0 ]
}

@test "report folds in the aggregate daemon (classified running via generalized pid_is_live)" {
  echo $$ > "$AGG_PID_FILE"
  printf '{"repo":"(aggregate)","pr_number":0,"last_poll_at":"2026-06-07T00:00:00Z","checks_status":"unknown","review_status":"unknown","daemon":{"pid":%s,"started_at":"2026-06-07T00:00:00Z","supervisor":"nohup"}}\n' "$$" > "$AGG_DAEMON_FILE"
  # A per-repo block too, to prove report's glob folds both in.
  printf '{"repo":"a/b","daemon":{"pid":111,"started_at":"2026-06-07T00:00:00Z","supervisor":"systemd"}}\n' > "$STATE_DIR/aaaaaaaaaaaa.sentinel.daemon.json"
  # ps reports a sentinel-aggregate cmdline for any live pid; pid 111 is dead so
  # kill -0 fails first and it is STALE. The aggregate (this bats pid) is live.
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "bash bin/sentinel-aggregate.sh --daemon-loop"
SH
  chmod +x "$MOCK/ps"
  PATH="$MOCK:$PATH" out=$(bash "$SCRIPT" report --state-dir "$STATE_DIR" --json)
  [ "$(echo "$out" | jq 'length')" -eq 2 ]
  # The aggregate daemon is present, tagged "(aggregate)", and RUNNING.
  echo "$out" | jq -e 'any(.[]; .repo == "(aggregate)" and .running == true)'
}

@test "restart --aggregate does not require --repo" {
  make_stub nohup 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
echo BeOS
SH
  chmod +x "$MOCK/uname"
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  sda restart
  [ "$status" -eq 0 ]
  # Stop then start: the aggregate loop re-spawned via nohup.
  wait_for_calls "$TMP/nohup.calls"
  grep -q "sentinel-aggregate" "$TMP/nohup.calls"
}

# --- large --interval must not silently kill the aggregate daemon ------------
# sentinel-daemon forwards ONLY --interval to the aggregate daemon (not
# --max-interval), so a large --interval must NOT trip the aggregate
# daemon-loop's default max-interval (1800) and die behind a "started" line.

@test "start --aggregate --interval 3600 starts cleanly (no max-interval death)" {
  make_stub launchctl 0
  sda start --interval 3600 --supervisor launchd
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.nyann.sentinel-aggregate.plist"
  [ -f "$plist" ]
  # The large interval is rendered and only --interval is plumbed through (no
  # --max-interval token), so the daemon-loop applies its default + clamps.
  grep -q "3600" "$plist"
  grep -q "sentinel-aggregate.sh" "$plist"
  ! grep -q "max-interval" "$plist"
  echo "$output" | grep -qi "aggregate daemon started"
  # Did not abort with the legacy ">= --interval" error.
  ! echo "$output" | grep -qi "must be >="
}

# --- delivery-secret propagation (supervised daemons don't inherit exports) --
# launchd agents + systemd --user units do not inherit interactive shell
# exports, so start must (a) warn for an enabled delivery channel whose secret
# env var is unset here, and (b) hand a SET secret to the supervisor's own
# environment WITHOUT writing it into the unit file.

@test "start warns when an enabled delivery channel's secret env var is unset" {
  make_stub launchctl 0
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{slack:{enabled:true, webhook_url_env:"NYANN_SLACK_WEBHOOK"}}}}' \
    > "$UR/preferences.json"
  unset NYANN_SLACK_WEBHOOK
  NYANN_USER_ROOT="$UR" sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  # The unset secret is surfaced loudly and the channel is flagged as skipped.
  echo "$output" | grep -q "NYANN_SLACK_WEBHOOK"
  echo "$output" | grep -qi "skipped"
}

@test "start propagates a SET delivery secret into the launchd environment (not the unit)" {
  make_stub launchctl 0
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{slack:{enabled:true, webhook_url_env:"NYANN_SLACK_WEBHOOK"}}}}' \
    > "$UR/preferences.json"
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/seekret"
  NYANN_USER_ROOT="$UR" sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  # launchctl setenv handed the daemon the secret in-memory...
  grep -q "setenv NYANN_SLACK_WEBHOOK" "$TMP/launchctl.calls"
  # ...and the secret was NOT written into the generated plist.
  ! grep -q "hooks.slack.test/seekret" "$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  unset NYANN_SLACK_WEBHOOK
}

@test "start propagates a SET delivery secret into the systemd environment" {
  make_stub systemctl 0
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{webhook:{enabled:true, url_env:"NYANN_HOOK"}}}}' \
    > "$UR/preferences.json"
  export NYANN_HOOK="https://example.test/seekret"
  NYANN_USER_ROOT="$UR" sd start --repo "$REPO" --supervisor systemd
  [ "$status" -eq 0 ]
  grep -q "import-environment NYANN_HOOK" "$TMP/systemctl.calls"
  ! grep -q "example.test/seekret" "$HOME/.config/systemd/user/nyann-sentinel.service"
  unset NYANN_HOOK
}

# --- delivery-secret teardown + supervisor scoping ---------------------------
# A propagated secret must not linger in the per-user launchd/systemd domain
# after stop/restart, and the nohup-fallback / nohup-default paths must never
# pollute a domain (nohup inherits the shell env directly).

@test "stop clears a propagated delivery secret from the launchd domain (unsetenv)" {
  printf '{"repo":"%s","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"launchd"}}\n' "$REPO" > "$DAEMON_FILE"
  make_stub launchctl 0
  make_stub kill 0
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{slack:{enabled:true, webhook_url_env:"NYANN_SLACK_WEBHOOK"}}}}' \
    > "$UR/preferences.json"
  NYANN_USER_ROOT="$UR" sd stop --repo "$REPO"
  [ "$status" -eq 0 ]
  # Teardown reclaimed the secret from the supervisor domain on stop.
  grep -q "unsetenv NYANN_SLACK_WEBHOOK" "$TMP/launchctl.calls"
}

@test "stop --aggregate clears a propagated delivery secret from the systemd domain (unset-environment)" {
  printf '{"repo":"(aggregate)","pr_number":0,"last_poll_at":"2026-06-07T00:00:00Z","checks_status":"unknown","review_status":"unknown","daemon":{"pid":999999,"started_at":"2026-06-07T00:00:00Z","supervisor":"systemd"}}\n' > "$AGG_DAEMON_FILE"
  make_stub systemctl 0
  cat > "$MOCK/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$MOCK/ps"
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{webhook:{enabled:true, url_env:"NYANN_HOOK"}}}}' \
    > "$UR/preferences.json"
  NYANN_USER_ROOT="$UR" sda stop
  [ "$status" -eq 0 ]
  grep -q "unset-environment NYANN_HOOK" "$TMP/systemctl.calls"
}

@test "start nohup-fallback (launchd load fails) clears the launchd domain" {
  make_stub launchctl 1   # launchctl present but load FAILS → nohup fallback
  make_stub nohup 0
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{slack:{enabled:true, webhook_url_env:"NYANN_SLACK_WEBHOOK"}}}}' \
    > "$UR/preferences.json"
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/seekret"
  NYANN_USER_ROOT="$UR" sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  wait_for_calls "$TMP/nohup.calls"
  echo "$output" | grep -qi "supervisor: nohup"
  # The load-fail fallback undoes the propagation: nohup inherits the shell env
  # directly, so the launchd domain must be cleared rather than left polluted.
  grep -q "unsetenv NYANN_SLACK_WEBHOOK" "$TMP/launchctl.calls"
  unset NYANN_SLACK_WEBHOOK
}

@test "start under the nohup-default supervisor never touches a launchd/systemd domain" {
  make_stub nohup 0
  cat > "$MOCK/uname" <<'SH'
#!/bin/sh
echo BeOS
SH
  chmod +x "$MOCK/uname"
  make_stub launchctl 0   # present, but the nohup-default branch must NOT use it
  make_stub systemctl 0
  UR="$TMP/ur"; mkdir -p "$UR"
  jq -n '{schemaVersion:3, notifications:{delivery:{slack:{enabled:true, webhook_url_env:"NYANN_SLACK_WEBHOOK"}}}}' \
    > "$UR/preferences.json"
  export NYANN_SLACK_WEBHOOK="https://hooks.slack.test/seekret"
  NYANN_USER_ROOT="$UR" sd start --repo "$REPO"
  [ "$status" -eq 0 ]
  wait_for_calls "$TMP/nohup.calls"
  echo "$output" | grep -qi "supervisor: nohup"
  # nohup inherits the shell env directly — nothing pushed into / cleared from a
  # supervisor domain, so neither launchctl nor systemctl was ever invoked.
  [ ! -f "$TMP/launchctl.calls" ]
  [ ! -f "$TMP/systemctl.calls" ]
  unset NYANN_SLACK_WEBHOOK
}

# --- per-repo --pr filter honoured under launchd/systemd ---------------------
# --pr must reach the supervised daemon (not just the nohup fallback), or a
# launchd/systemd daemon silently watches ALL PRs instead of the requested one.

@test "start --pr renders the filter into the launchd plist" {
  make_stub launchctl 0
  sd start --repo "$REPO" --pr 5 --supervisor launchd
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  [ -f "$plist" ]
  grep -q -- "--pr" "$plist"
  grep -q "<string>5</string>" "$plist"
  # No leftover ${...} placeholders (incl. ${PR_ARGS}) when --pr IS set.
  ! grep -q '\${' "$plist"
}

@test "start without --pr leaves no --pr token (or leftover placeholder) in the plist" {
  make_stub launchctl 0
  sd start --repo "$REPO" --supervisor launchd
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.nyann.sentinel.plist"
  ! grep -q -- "--pr" "$plist"
  ! grep -q 'PR_ARGS' "$plist"
  ! grep -q '\${' "$plist"
}

@test "start --pr renders the filter into the systemd unit ExecStart" {
  make_stub systemctl 0
  sd start --repo "$REPO" --pr 9 --supervisor systemd
  [ "$status" -eq 0 ]
  unit="$HOME/.config/systemd/user/nyann-sentinel.service"
  [ -f "$unit" ]
  grep -q -- "--pr 9" "$unit"
  ! grep -q '\${' "$unit"
}

@test "start rejects a non-integer --pr" {
  run bash "$SCRIPT" start --repo "$REPO" --pr abc --state-dir "$STATE_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "positive integer"
}

# --- schema: daemon block validates -----------------------------------------

@test "SentinelState with a daemon block validates against the schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{repo:"o/r", pr_number:0, last_poll_at:"2026-06-07T00:00:00Z", checks_status:"unknown", review_status:"unknown", daemon:{pid:4242, started_at:"2026-06-07T00:00:00Z", supervisor:"launchd"}}' > "$TMP/d.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/sentinel-state.schema.json" "$TMP/d.json"
}

@test "an invalid supervisor value is rejected by the schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{repo:"o/r", pr_number:0, last_poll_at:"2026-06-07T00:00:00Z", checks_status:"unknown", review_status:"unknown", daemon:{pid:1, started_at:"2026-06-07T00:00:00Z", supervisor:"cron"}}' > "$TMP/bad.json"
  run "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/sentinel-state.schema.json" "$TMP/bad.json"
  [ "$status" -ne 0 ]
}
