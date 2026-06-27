#!/usr/bin/env bats
# Multi-repo sentinel aggregation — watch-list management, multi-repo poll
# with a single globally rate-limit-aware scheduler, and the aggregated,
# repo-tagged read via read-notifications.sh --all. Real gh polling is
# replaced with a stub ci-sentinel and a PATH-stubbed gh.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-agg.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  WL="$TMP/watch-list.json"
  STATE_DIR="$TMP/state"
  NOTIF_DIR="$TMP/notifs"
  mkdir -p "$STATE_DIR" "$NOTIF_DIR"
  AGG="$REPO_ROOT/bin/sentinel-aggregate.sh"
  READ="$REPO_ROOT/bin/read-notifications.sh"
}

teardown() { rm -rf "$TMP"; }

# Per-repo queue hash — MUST match the scripts' repo_hash().
qhash() { printf '%s' "$1" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12; }

# A stub ci-sentinel that appends one notification to the repo's queue. Lets
# the multi-repo poll exercise the real merge path without touching GitHub.
make_sentinel() {
  cat > "$TMP/fake-sentinel.sh" <<'EOF'
#!/usr/bin/env bash
repo=""; nd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --notif-dir) nd="$2"; shift 2 ;;
    --pr) shift 2 ;;
    *) shift ;;
  esac
done
h=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12)
jq -n --arg m "CI failed on $repo" \
  '{timestamp:"2026-06-27T00:00:00Z", source:"sentinel", severity:"critical", message:$m, context:{pr:1}}' \
  >> "$nd/$h.jsonl"
EOF
  chmod +x "$TMP/fake-sentinel.sh"
  printf '%s' "$TMP/fake-sentinel.sh"
}

# A stub ci-sentinel that records every invocation by touching a marker. Used
# to prove the backoff path skips polling entirely.
make_sentinel_marker() {
  cat > "$TMP/marker-sentinel.sh" <<EOF
#!/usr/bin/env bash
echo invoked >> "$TMP/invoked.log"
EOF
  chmod +x "$TMP/marker-sentinel.sh"
  printf '%s' "$TMP/marker-sentinel.sh"
}

# A PATH directory whose gh stub reports <remaining> core budget.
gh_path() {
  local remaining="$1" dir="$TMP/gh-$remaining"
  mkdir -p "$dir"
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then echo $remaining; exit 0; fi
exit 0
EOF
  chmod +x "$dir/gh"
  printf '%s' "$dir"
}

# --- watch-list management --------------------------------------------------

@test "--add creates the watch-list with the repo" {
  run bash "$AGG" --add o/a --watch-list "$WL"
  [ "$status" -eq 0 ]
  [ -f "$WL" ]
  [ "$(jq -r '.[0].repo' "$WL")" = "o/a" ]
}

@test "--add is idempotent (no duplicate on re-add)" {
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/a --watch-list "$WL"
  [ "$(jq '[.[] | select(.repo=="o/a")] | length' "$WL")" -eq 1 ]
}

@test "--add --pr merges PR numbers into prs[] (deduped, sorted)" {
  bash "$AGG" --add o/b --pr 7 --watch-list "$WL"
  bash "$AGG" --add o/b --pr 7 --watch-list "$WL"
  bash "$AGG" --add o/b --pr 3 --watch-list "$WL"
  [ "$(jq -c '.[] | select(.repo=="o/b") | .prs' "$WL")" = "[3,7]" ]
}

@test "--add rejects a malformed repo (no slash)" {
  run bash "$AGG" --add notarepo --watch-list "$WL"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid repo"
  [ ! -f "$WL" ]
}

@test "--add rejects a path-traversal repo slug" {
  run bash "$AGG" --add "../etc/passwd" --watch-list "$WL"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid repo"
}

@test "--add rejects a leading-dash repo (option injection)" {
  run bash "$AGG" --add "-x/y" --watch-list "$WL"
  [ "$status" -ne 0 ]
}

@test "--add rejects a non-integer --pr" {
  run bash "$AGG" --add o/a --pr abc --watch-list "$WL"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "positive integer"
}

@test "--add rejects --pr 0 (watch-list schema requires prs >= 1)" {
  run bash "$AGG" --add o/a --pr 0 --watch-list "$WL"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "positive integer"
  # Nothing written — a 0 would violate watch-list.schema.json's prs minimum:1.
  [ ! -f "$WL" ]
}

@test "--remove deletes a repo from the watch-list" {
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --watch-list "$WL"
  bash "$AGG" --remove o/a --watch-list "$WL"
  [ "$(jq 'length' "$WL")" -eq 1 ]
  [ "$(jq -r '.[0].repo' "$WL")" = "o/b" ]
}

@test "--remove of an absent repo is a clean no-op" {
  bash "$AGG" --add o/a --watch-list "$WL"
  run bash "$AGG" --remove o/zzz --watch-list "$WL"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$WL")" -eq 1 ]
}

@test "--list prints the watch-list array" {
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --pr 4 --watch-list "$WL"
  run bash "$AGG" --list --watch-list "$WL"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].repo')" = "o/a" ]
  [ "$(echo "$output" | jq -c '.[1].prs')" = "[4]" ]
}

@test "--list on a missing watch-list prints []" {
  run bash "$AGG" --list --watch-list "$WL"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

@test "a mode flag is required" {
  run bash "$AGG" --watch-list "$WL"
  [ "$status" -ne 0 ]
}

@test "two modes at once is rejected" {
  run bash "$AGG" --list --poll --watch-list "$WL"
  [ "$status" -ne 0 ]
}

@test "watch-list written by --add validates against the schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --pr 7 --watch-list "$WL"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/watch-list.schema.json" "$WL"
}

# --- poll ------------------------------------------------------------------

@test "--poll on an empty watch-list is a clean no-op summary" {
  ghdir="$(gh_path 5000)"
  # Capture stdout only — the human-readable [nyann] logs go to stderr and
  # would otherwise corrupt the JSON summary parse.
  summary="$(env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ]
  echo "$summary" | jq -e '.polled == [] and .backoff == false'
}

@test "--poll iterates the watch-list and runs the sentinel per repo (merged notifications)" {
  sentinel="$(make_sentinel)"
  ghdir="$(gh_path 5000)"
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --pr 5 --watch-list "$WL"
  run env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --sentinel "$sentinel"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.polled | sort == ["o/a","o/b"]'
  # Both per-repo queues received an entry.
  [ -s "$NOTIF_DIR/$(qhash o/a).jsonl" ]
  [ -s "$NOTIF_DIR/$(qhash o/b).jsonl" ]
}

@test "read-notifications --all merges queues across repos and tags context.repo" {
  sentinel="$(make_sentinel)"
  ghdir="$(gh_path 5000)"
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --watch-list "$WL"
  env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --sentinel "$sentinel"
  run bash "$READ" --all --watch-list "$WL" --notif-dir "$NOTIF_DIR" --peek
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # Every entry is repo-tagged via context.repo and the tags cover both repos.
  echo "$output" | jq -e 'map(.context.repo) | sort == ["o/a","o/b"]'
  echo "$output" | jq -e 'all(.[]; .context.repo != null)'
}

@test "read-notifications --all drains (truncates) every watched queue" {
  repo_a="o/a"; repo_b="o/b"
  bash "$AGG" --add "$repo_a" --watch-list "$WL"
  bash "$AGG" --add "$repo_b" --watch-list "$WL"
  fa="$NOTIF_DIR/$(qhash "$repo_a").jsonl"
  fb="$NOTIF_DIR/$(qhash "$repo_b").jsonl"
  jq -n '{timestamp:"2026-06-27T00:00:00Z", source:"sentinel", severity:"info", message:"a", context:{}}' > "$fa"
  jq -n '{timestamp:"2026-06-27T00:00:01Z", source:"sentinel", severity:"info", message:"b", context:{}}' > "$fb"
  run bash "$READ" --all --watch-list "$WL" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 2 ]
  # Both queues truncated (drained) after the read.
  [ ! -s "$fa" ]
  [ ! -s "$fb" ]
}

@test "read-notifications --all on an empty/missing watch-list returns []" {
  run bash "$READ" --all --watch-list "$WL" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. == []'
}

@test "--poll backs off GLOBALLY when the rate budget is low (no repo polled)" {
  marker="$(make_sentinel_marker)"
  ghdir="$(gh_path 5)"
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --watch-list "$WL"
  # Capture stdout only — the backoff warning goes to stderr.
  summary="$(env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --sentinel "$marker" --rate-reserve 100 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ]
  # Global backoff: summary flags backoff, both repos skipped, none polled.
  echo "$summary" | jq -e '.backoff == true and .polled == [] and (.skipped | sort == ["o/a","o/b"])'
  # The sentinel was never invoked — no marker file was written.
  [ ! -f "$TMP/invoked.log" ]
}

@test "--poll adaptive interval grows on consecutive backoffs and persists scheduler state" {
  ghdir="$(gh_path 5)"
  bash "$AGG" --add o/a --watch-list "$WL"
  # First backoff: 120 -> 240.
  env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --interval 120 --rate-reserve 100 >/dev/null
  sched="$STATE_DIR/aggregate-scheduler.json"
  [ "$(jq -r '.current_interval' "$sched")" -eq 240 ]
  [ "$(jq -r '.consecutive_backoffs' "$sched")" -eq 1 ]
  # Second consecutive backoff grows further (240-equivalent: 120 -> 480).
  env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --interval 120 --rate-reserve 100 >/dev/null
  [ "$(jq -r '.consecutive_backoffs' "$sched")" -eq 2 ]
  [ "$(jq -r '.current_interval' "$sched")" -gt 240 ]
}

@test "--poll soft-skips when gh is missing (no scheduler crash)" {
  # Build a PATH that lacks gh so the rate oracle / sentinel are unavailable.
  ngh="$TMP/nogh"; mkdir -p "$ngh"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for exe in "$d"/*; do
      [ -x "$exe" ] || continue
      b="$(basename "$exe")"
      [ "$b" = gh ] && continue
      [ -e "$ngh/$b" ] || ln -s "$exe" "$ngh/$b" 2>/dev/null || true
    done
  done
  bash "$AGG" --add o/a --watch-list "$WL"
  run env PATH="$ngh" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "gh CLI not installed"
}

@test "--poll still prints a scheduler summary (regression after daemon-loop extraction)" {
  # run_poll_cycle is a pure extraction of the old --poll body; prove --poll's
  # observable contract (one cycle, one summary, per-repo fan-out) is unchanged.
  sentinel="$(make_sentinel)"
  ghdir="$(gh_path 5000)"
  bash "$AGG" --add o/a --watch-list "$WL"
  summary="$(env PATH="$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --sentinel "$sentinel" 2>/dev/null)"
  echo "$summary" | jq -e 'has("current_interval") and has("polled") and has("backoff")'
  echo "$summary" | jq -e '.polled == ["o/a"] and .backoff == false'
  # The cycle still persists the scheduler state file.
  [ -s "$STATE_DIR/aggregate-scheduler.json" ]
}

# --- --daemon-loop / --stop (v1.13.0 P10) -----------------------------------
# The supervised aggregate loop. Exercised with a SHORT --max-runtime / an
# empty watch-list so each cycle is cheap and the loop self-terminates in a
# couple of seconds — never a real long-running daemon. There is ONE aggregate
# daemon per user, so it uses FIXED file names (aggregate.sentinel.{pid,daemon
# .json}), not repo-hashed ones.

@test "--daemon-loop self-terminates at --max-runtime and reaps its state" {
  # Empty watch-list → each cycle returns early (cheap, no gh needed). A 2s cap
  # exits cleanly almost immediately — bounded, not long-running.
  run bash "$AGG" --daemon-loop --interval 1 --max-runtime 2 \
    --watch-list "$WL" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "max-runtime"
  # Clean exit reaps the fixed-name pid file + daemon liveness block.
  [ ! -f "$STATE_DIR/aggregate.sentinel.pid" ]
  [ ! -f "$STATE_DIR/aggregate.sentinel.daemon.json" ]
}

@test "--daemon-loop writes a schema-valid liveness block, then --stop reaps it" {
  # Run the daemon in the BACKGROUND with a longer interval so it sits in its
  # sleep (pid + block present); a short max-runtime backstops a failed --stop
  # so the suite can't hang. Empty watch-list keeps each cycle cheap.
  pidf="$STATE_DIR/aggregate.sentinel.pid"
  blockf="$STATE_DIR/aggregate.sentinel.daemon.json"
  bash "$AGG" --daemon-loop --interval 2 --max-runtime 10 \
    --watch-list "$WL" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup &
  daemon_pid=$!
  # Bounded wait for the daemon to write its pid + liveness block.
  i=0; while (( i < 50 )); do [ -s "$pidf" ] && [ -s "$blockf" ] && break; sleep 0.1; i=$(( i + 1 )); done
  [ -s "$pidf" ]
  [ -s "$blockf" ]
  # The block carries the reserved aggregate identity + a daemon block.
  [ "$(jq -r '.repo' "$blockf")" = "(aggregate)" ]
  [ "$(jq -r '.pr_number' "$blockf")" -eq 0 ]
  [ "$(jq -r '.daemon.supervisor' "$blockf")" = "nohup" ]
  [ "$(jq -r '.daemon.pid' "$blockf")" = "$daemon_pid" ]
  # ... and validates against the SentinelState schema when a validator exists.
  if command -v check-jsonschema >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1; then
    if command -v check-jsonschema >/dev/null 2>&1; then VALIDATE=(check-jsonschema); else VALIDATE=(uvx --quiet check-jsonschema); fi
    "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/sentinel-state.schema.json" "$blockf"
  fi
  # --stop kills it (PID-reuse guard matches the real cmdline) and reaps both.
  run bash "$AGG" --stop --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
  # Let the daemon fully exit (its own cleanup also reaps) before asserting.
  wait "$daemon_pid" 2>/dev/null || true
  [ ! -f "$pidf" ]
  [ ! -f "$blockf" ]
}

@test "--daemon-loop refuses to start a second aggregate daemon (single-instance)" {
  # Pre-seed the aggregate pid file pointing at a live *sentinel-aggregate*-
  # looking process (this bats process via a ps stub) so the guard fires.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/ps" <<'SH'
#!/bin/sh
echo "bash bin/sentinel-aggregate.sh --daemon-loop"
SH
  chmod +x "$TMP/mock/ps"
  echo $$ > "$STATE_DIR/aggregate.sentinel.pid"   # live pid = this bats process.
  PATH="$TMP/mock:$PATH" run bash "$AGG" --daemon-loop --interval 1 --max-runtime 2 \
    --watch-list "$WL" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already running"
  # The pre-existing pid file (pointing at us) must NOT have been reaped.
  [ -f "$STATE_DIR/aggregate.sentinel.pid" ]
  [ "$(cat "$STATE_DIR/aggregate.sentinel.pid")" = "$$" ]
}

@test "--stop is a clean no-op when no aggregate daemon is running" {
  run bash "$AGG" --stop --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
}

@test "--daemon-loop survives a cycle where run_poll_cycle returns non-zero" {
  # Force EVERY cycle's run_poll_cycle to fail: pre-hold the per-cycle
  # scheduler lock so nyann::lock times out + dies inside the subshell. A
  # `sleep` stub makes the lock-retry loop instant so the test is bounded by
  # --max-runtime (~1s), not the 10s lock timeout. With the `|| summary=""`
  # fallback the loop keeps running and exits CLEANLY at --max-runtime; WITHOUT
  # it, `set -e` would abort the daemon mid-loop (non-zero, no clean message).
  bash "$AGG" --add o/a --watch-list "$WL"
  mkdir -p "$STATE_DIR"
  mkdir "$STATE_DIR/aggregate-scheduler.lock"   # held, never released

  stub="$TMP/loopstub"; mkdir -p "$stub"
  printf '#!/bin/sh\nexit 0\n' > "$stub/sleep"
  printf '#!/bin/sh\nexit 0\n' > "$stub/gh"
  chmod +x "$stub/sleep" "$stub/gh"

  run env PATH="$stub:$PATH" bash "$AGG" --daemon-loop --interval 1 --max-runtime 1 \
    --watch-list "$WL" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "max-runtime"
}

@test "--daemon-loop rejects a non-numeric --interval" {
  run bash "$AGG" --daemon-loop --interval abc --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "interval"
}

@test "--daemon-loop rejects a non-numeric --max-interval" {
  run bash "$AGG" --daemon-loop --max-interval abc --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "max-interval"
}

@test "--daemon-loop rejects an unknown --supervisor" {
  run bash "$AGG" --daemon-loop --supervisor cron --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "supervisor"
}

@test "--daemon-loop rejects --max-interval 0 (a 0 would busy-spin on backoff)" {
  # A 0 max-interval clamps the adaptive backoff interval to 0; the 1s-slice
  # sleep then never sleeps → a tight gh-hammering re-poll. Reject it up front.
  run bash "$AGG" --daemon-loop --max-interval 0 --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "max-interval"
}

@test "--daemon-loop clamps a --max-interval below --interval up to --interval (no die)" {
  # A --max-interval under --interval just means no room to back off past the
  # base cadence — the loop must CLAMP the ceiling up and keep running, not die.
  # (sentinel-daemon.sh forwards only --interval, so a large --interval would
  # otherwise hit the default max_interval=1800 and silently kill the daemon.)
  # Empty watch-list + short max-runtime keeps it bounded.
  run bash "$AGG" --daemon-loop --interval 2 --max-interval 1 --max-runtime 2 \
    --watch-list "$WL" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" --supervisor nohup
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "max-runtime"
  # It did NOT abort with the old ">= --interval" error.
  ! echo "$output" | grep -qi "must be >="
}

# --- aggregate skips a repo with its own live per-repo daemon (no double-send) -

@test "--poll skips a repo that already has a live per-repo daemon, still polls others" {
  # If a per-repo daemon AND the aggregate both cover a repo, both poll+deliver
  # it → duplicate notifications. The aggregate must skip a repo whose
  # <repo-hash>.sentinel.pid points at a LIVE ci-sentinel process.
  sentinel="$(make_sentinel)"
  ghdir="$(gh_path 5000)"
  bash "$AGG" --add o/a --watch-list "$WL"
  bash "$AGG" --add o/b --watch-list "$WL"
  # o/a has a live per-repo daemon: pid file points at this bats process and a
  # ps stub makes its cmdline look like ci-sentinel. o/b has none.
  echo $$ > "$STATE_DIR/$(qhash o/a).sentinel.pid"
  mock="$TMP/mock"; mkdir -p "$mock"
  cat > "$mock/ps" <<'SH'
#!/bin/sh
echo "bash bin/ci-sentinel.sh --daemon-loop --repo o/a"
SH
  chmod +x "$mock/ps"
  summary="$(env PATH="$mock:$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --sentinel "$sentinel" 2>/dev/null)"
  # o/a is in skipped (covered by its own daemon); only o/b is polled.
  echo "$summary" | jq -e '.polled == ["o/b"]'
  echo "$summary" | jq -e '(.skipped | index("o/a")) != null'
  # The aggregate never invoked the sentinel for o/a (its queue stays empty)...
  [ ! -s "$NOTIF_DIR/$(qhash o/a).jsonl" ]
  # ...but did for o/b.
  [ -s "$NOTIF_DIR/$(qhash o/b).jsonl" ]
}

@test "--poll does NOT skip a repo whose per-repo pid file is stale (dead process)" {
  # A stale/dead per-repo pid file must not suppress aggregation — only a LIVE
  # ci-sentinel process counts. The repo is still polled.
  sentinel="$(make_sentinel)"
  ghdir="$(gh_path 5000)"
  bash "$AGG" --add o/a --watch-list "$WL"
  # Dead pid (very unlikely to be live) → the liveness guard fails → not skipped.
  echo 999999 > "$STATE_DIR/$(qhash o/a).sentinel.pid"
  mock="$TMP/mock"; mkdir -p "$mock"
  cat > "$mock/ps" <<'SH'
#!/bin/sh
echo "unrelated"
SH
  chmod +x "$mock/ps"
  summary="$(env PATH="$mock:$ghdir:$PATH" bash "$AGG" --poll --watch-list "$WL" \
    --notif-dir "$NOTIF_DIR" --state-dir "$STATE_DIR" --sentinel "$sentinel" 2>/dev/null)"
  echo "$summary" | jq -e '.polled == ["o/a"]'
  [ -s "$NOTIF_DIR/$(qhash o/a).jsonl" ]
}
