#!/usr/bin/env bash
# ci-sentinel.sh — poll one or all open PRs on a repo for state changes
# and emit Notification entries when state transitions occur.
#
# Usage:
#   ci-sentinel.sh --repo <owner/repo> [--pr <number>]
#                  [--interval <seconds>] [--max-runtime <seconds>]
#                  [--one-shot | --daemon-loop] [--supervisor <name>]
#                  [--state-dir <dir>] [--notif-dir <dir>]
#                  [--stop]
#
# Modes:
#   default       — single poll cycle (caller wraps in `nohup` or a launchd
#                   plist for backgrounded runs).
#   --one-shot    — explicit; same as default. Surfaced for clarity.
#   --daemon-loop — supervised long-running mode (v1.13.0 P8). Polls every
#                   --interval seconds until --max-runtime (default 8h) is
#                   reached or a SIGTERM/SIGINT arrives, with exponential
#                   backoff when gh calls fail repeatedly. Re-resolves the
#                   open-PR list each cycle so new PRs are picked up. Refuses
#                   to start if a live sentinel already owns this repo
#                   (single-instance). Normally launched by bin/sentinel-daemon.sh
#                   under launchd / systemd / nohup — not invoked by hand.
#   --supervisor  — record which supervisor launched the loop (launchd|systemd
#                   |nohup) into the SentinelState `daemon` block. Advisory.
#   --stop        — kill any sentinel daemon for the current repo via the
#                   pid file in <state-dir>.
#
# State file: <state-dir>/<repo-hash>.sentinel.json (SentinelState)
# PID file:   <state-dir>/<repo-hash>.sentinel.pid
# Notifications: appended NDJSON to <notif-dir>/<repo-hash>.jsonl
#
# Notifications only fire on STATE TRANSITIONS (e.g., pending → failure).
# Repeated polls with the same state produce no output.
#
# Requires gh CLI. Soft-skips when gh isn't installed.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

repo=""
pr_filter=""
interval=120
# Default hard cap is 8h (28800s) for the daemon loop — the orphan backstop
# from the P8 spec. One-shot mode never reads it.
max_runtime=28800
# shellcheck disable=SC2034  # always-true sentinel for one-shot mode; the
# daemonize toggle below (--daemon-loop) is the real mode switch.
one_shot=true
daemon_loop=false
supervisor=""
state_dir="${HOME}/.claude/nyann/cache"
notif_dir="${HOME}/.claude/nyann/notifications"
stop_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        repo="${2-}"; shift 2 ;;
    --repo=*)      repo="${1#--repo=}"; shift ;;
    --pr)          pr_filter="${2-}"; shift 2 ;;
    --pr=*)        pr_filter="${1#--pr=}"; shift ;;
    --interval)    interval="${2-}"; shift 2 ;;
    --interval=*)  interval="${1#--interval=}"; shift ;;
    --max-runtime) max_runtime="${2-}"; shift 2 ;;
    --max-runtime=*) max_runtime="${1#--max-runtime=}"; shift ;;
    --one-shot)    one_shot=true; shift ;;
    --daemon-loop) daemon_loop=true; shift ;;
    --supervisor)  supervisor="${2-}"; shift 2 ;;
    --supervisor=*) supervisor="${1#--supervisor=}"; shift ;;
    --state-dir)   state_dir="${2-}"; shift 2 ;;
    --state-dir=*) state_dir="${1#--state-dir=}"; shift ;;
    --notif-dir)   notif_dir="${2-}"; shift 2 ;;
    --notif-dir=*) notif_dir="${1#--notif-dir=}"; shift ;;
    --stop)        stop_mode=true; shift ;;
    -h|--help)     sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || nyann::die "--repo <owner/repo> is required"
# Validate --pr immediately so we never feed a non-integer into
# `--argjson pr "$pr_no"` later — that would make jq exit non-zero and
# the `>` redirect would truncate the per-PR state file to empty,
# destroying prior state.
if [[ -n "$pr_filter" ]] && ! [[ "$pr_filter" =~ ^[0-9]+$ ]]; then
  nyann::die "--pr must be a positive integer (got: $pr_filter)"
fi
# In daemon-loop mode interval + max_runtime are live inputs — validate them
# so a typo can't put the loop into a tight no-sleep spin or an unbounded run
# (the orphan backstop depends on a sane cap).
if $daemon_loop; then
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
    nyann::die "--interval must be a positive integer of seconds (got: $interval)"
  fi
  if ! [[ "$max_runtime" =~ ^[0-9]+$ ]] || (( max_runtime < 1 )); then
    nyann::die "--max-runtime must be a positive integer of seconds (got: $max_runtime)"
  fi
  case "${supervisor:-nohup}" in
    launchd|systemd|nohup|"") ;;
    *) nyann::die "--supervisor must be one of launchd|systemd|nohup (got: $supervisor)" ;;
  esac
fi
# Touch one_shot so shellcheck sees it consumed. It's part of the public CLI
# contract (the explicit alias for the default single-poll mode); --daemon-loop
# is the real long-running toggle.
: "$one_shot"
mkdir -p "$state_dir" "$notif_dir" 2>/dev/null || true

repo_hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12)
pid_file="$state_dir/${repo_hash}.sentinel.pid"

if $stop_mode; then
  if [[ -f "$pid_file" ]]; then
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      # Guard against PID reuse: a crashed sentinel can leave a stale pid
      # file whose number the OS later recycled for an unrelated process.
      # Only kill if the live process actually looks like a sentinel.
      proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
      if [[ "$proc_cmd" == *ci-sentinel* ]]; then
        kill "$pid" 2>/dev/null || true
        echo "[nyann sentinel] stopped pid $pid"
      else
        echo "[nyann sentinel] pid $pid is not a sentinel (stale pid file) — not killing" >&2
      fi
    fi
    rm -f "$pid_file"
  fi
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "[nyann sentinel] gh CLI not installed — skipping" >&2
  exit 0
fi

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

append_notification() {
  local pr_no="$1" severity="$2" msg="$3" context_json="${4-{}}"
  local notif_file="$notif_dir/${repo_hash}.jsonl"
  # Hold the SAME named lock the reader uses (read-notifications.sh derives
  # it from the same queue path) so an append can't land in the inode the
  # reader is about to mv-then-rm. Lock name = "${notif_file}.lock". Keep
  # the hold time minimal — just the jq + append redirect.
  local lock_dir="${notif_file}.lock"
  nyann::lock "$lock_dir"
  jq -n \
    --arg ts "$(now)" \
    --arg source "sentinel" \
    --arg severity "$severity" \
    --arg message "$msg" \
    --argjson context "$context_json" \
    '{timestamp:$ts, source:$source, severity:$severity, message:$message, context:$context}' \
    >> "$notif_file"
  nyann::unlock "$lock_dir"
}

poll_pr() {
  local pr_no="$1"
  local state_file="$state_dir/${repo_hash}.pr${pr_no}.sentinel.json"

  # Fetch current state via gh.
  local pr_json
  if ! pr_json=$(gh pr view "$pr_no" --repo "$repo" --json number,headRefName,baseRefName,state,mergeable,reviewDecision,statusCheckRollup 2>/dev/null); then
    return 1
  fi

  local checks_status review_status head base merged
  merged=$(jq -r '.state == "MERGED"' <<<"$pr_json")
  head=$(  jq -r '.headRefName // ""' <<<"$pr_json")
  base=$(  jq -r '.baseRefName // ""' <<<"$pr_json")

  # Aggregate check rollup status. statusCheckRollup is an array of checks.
  # We pick the worst: failure > pending > success.
  checks_status=$(jq -r '
    .statusCheckRollup // []
    | map(.conclusion // .status)
    | if any(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT") then "failure"
      elif any(. == "IN_PROGRESS" or . == "QUEUED" or . == "PENDING") then "pending"
      elif length == 0 then "unknown"
      elif all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "success"
      else "unknown" end
  ' <<<"$pr_json")

  review_status=$(jq -r '
    .reviewDecision
    | if . == "CHANGES_REQUESTED" then "changes-requested"
      elif . == "APPROVED" then "approved"
      elif . == "REVIEW_REQUIRED" or . == null or . == "" then "no-reviews"
      else "unknown" end
  ' <<<"$pr_json")

  # Diff against cached state.
  local prev_checks="" prev_review=""
  if [[ -f "$state_file" ]]; then
    prev_checks=$(jq -r '.checks_status // ""' "$state_file" 2>/dev/null)
    prev_review=$(jq -r '.review_status // ""' "$state_file" 2>/dev/null)
  fi

  # Fire on any state change, INCLUDING first contact (prev_checks empty).
  # A PR that is already failing / already approved when the sentinel first
  # runs is exactly the state the user wants surfaced — suppressing the first
  # poll left such PRs silent forever (the `merged` branch below already
  # fires on first contact; this keeps checks/review consistent with it).
  # Repeat polls with the same state are still suppressed by `prev != cur`.
  if [[ "$prev_checks" != "$checks_status" ]]; then
    local checks_from="${prev_checks:-pending}"
    case "$checks_status" in
      failure) append_notification "$pr_no" "critical" "PR #${pr_no}: CI failed" "$(jq -n --argjson pr "$pr_no" --arg from "$checks_from" '{pr:$pr, transition: "checks: \($from) → failure"}')" ;;
      success) append_notification "$pr_no" "info"     "PR #${pr_no}: all checks passed — ready to merge" "$(jq -n --argjson pr "$pr_no" --arg from "$checks_from" '{pr:$pr, transition: "checks: \($from) → success"}')" ;;
    esac
  fi
  if [[ "$prev_review" != "$review_status" ]]; then
    case "$review_status" in
      changes-requested) append_notification "$pr_no" "warning" "PR #${pr_no}: reviewer requested changes" "$(jq -n --argjson pr "$pr_no" '{pr:$pr, transition: "review: → changes-requested"}')" ;;
      approved)          append_notification "$pr_no" "info"    "PR #${pr_no}: approved" "$(jq -n --argjson pr "$pr_no" '{pr:$pr, transition: "review: → approved"}')" ;;
    esac
  fi
  if [[ "$merged" == "true" ]]; then
    if [[ ! -f "$state_file" ]] || [[ "$(jq -r '.merged // false' "$state_file" 2>/dev/null)" != "true" ]]; then
      append_notification "$pr_no" "info" "PR #${pr_no}: merged into ${base}" "$(jq -n --argjson pr "$pr_no" --arg base "$base" '{pr:$pr, base:$base}')"
    fi
  fi

  # Write updated state.
  jq -n \
    --arg repo "$repo" \
    --argjson pr "$pr_no" \
    --arg base "$base" \
    --arg head "$head" \
    --arg ts "$(now)" \
    --arg cs "$checks_status" \
    --arg rs "$review_status" \
    --argjson merged "$merged" \
    '{repo:$repo, pr_number:$pr, base_branch:$base, head_branch:$head, last_poll_at:$ts, checks_status:$cs, review_status:$rs, merged:$merged}' \
    > "$state_file"
}

# resolve_prs — print the PR numbers to poll, one per line. Either the
# explicit --pr or all open PRs on the repo. Re-run each daemon cycle so a
# newly opened PR is picked up; gh failure prints nothing (caller treats an
# empty list as "no PRs this cycle", not a crash).
resolve_prs() {
  if [[ -n "$pr_filter" ]]; then
    printf '%s\n' "$pr_filter"
    return 0
  fi
  gh pr list --repo "$repo" --state open --json number --jq '.[].number' 2>/dev/null || true
}

# write_daemon_block — record per-repo daemon liveness into the SentinelState
# `daemon` block (schema-additive). Lives in its own file alongside the per-PR
# state so doctor / status / triage can report "sentinel alive". Best-effort:
# a failed write never aborts the loop.
write_daemon_block() {
  local started_at="$1" sup="$2"
  local daemon_file="$state_dir/${repo_hash}.sentinel.daemon.json"
  jq -n \
    --arg repo "$repo" \
    --arg ts "$(now)" \
    --argjson pid "$$" \
    --arg started "$started_at" \
    --arg sup "$sup" \
    '{repo:$repo, pr_number:0, last_poll_at:$ts, checks_status:"unknown", review_status:"unknown",
      daemon: {pid:$pid, started_at:$started, supervisor:$sup}}' \
    > "$daemon_file" 2>/dev/null || true
}

# poll_one_pass — poll every currently-open PR once. Returns 0 if at least one
# PR was polled successfully (or there were genuinely no PRs), non-zero ONLY
# when every gh fetch failed — the signal the daemon loop uses to back off.
poll_one_pass() {
  local prs=() n any_ok=1 had_prs=0
  while IFS= read -r n; do
    [[ -n "$n" ]] && prs+=("$n")
  done < <( resolve_prs )

  (( ${#prs[@]} == 0 )) && return 0   # no open PRs this cycle is not a failure
  for n in "${prs[@]}"; do
    had_prs=1
    if poll_pr "$n"; then
      any_ok=0
    else
      echo "[nyann sentinel] poll failed for PR #$n" >&2
    fi
  done
  # Failure = we had PRs but every fetch failed (rate-limit / network / auth).
  (( had_prs == 1 && any_ok == 1 )) && return 1
  return 0
}

# deliver_notifications — P9 external delivery hook. PEEKS the queue (so the
# session-start drain still surfaces the same entries) and pipes them through
# notify-deliver.sh, which dedups per its own marker (nothing is sent twice,
# even across the eventual drain) and is a silent no-op when no channel is
# configured. Best-effort: a delivery failure never affects polling. Because
# the aggregate scheduler (P10) invokes this script one-shot per repo, wiring
# delivery HERE — at the single notification producer — covers the single-repo
# daemon, one-shot, and aggregate paths alike, with no per-caller duplication.
deliver_notifications() {
  local nd="${_script_dir}/notify-deliver.sh"
  local rn="${_script_dir}/read-notifications.sh"
  [[ -x "$nd" && -x "$rn" ]] || return 0
  "$rn" --repo "$repo" --notif-dir "$notif_dir" --peek 2>/dev/null \
    | "$nd" --repo "$repo" --cache-dir "$state_dir" 2>/dev/null || true
}

if $daemon_loop; then
  # --- Single-instance guard ------------------------------------------------
  # Refuse to start a second daemon for this repo. Reuse the same liveness +
  # PID-reuse check the --stop path uses: a live process whose cmdline still
  # looks like a sentinel owns the repo. A stale pid (dead / recycled) is
  # reclaimed silently.
  if [[ -f "$pid_file" ]]; then
    existing=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$existing" ]] && kill -0 "$existing" 2>/dev/null; then
      existing_cmd=$(ps -p "$existing" -o command= 2>/dev/null || ps -p "$existing" -o comm= 2>/dev/null || true)
      if [[ "$existing_cmd" == *ci-sentinel* ]]; then
        echo "[nyann sentinel] daemon already running for $repo (pid $existing) — not starting a second" >&2
        exit 0
      fi
    fi
    # Stale pid file — reclaim it.
    rm -f "$pid_file" 2>/dev/null || true
  fi

  printf '%s\n' "$$" > "$pid_file" 2>/dev/null || true

  daemon_started_at="$(now)"
  daemon_supervisor="${supervisor:-nohup}"
  write_daemon_block "$daemon_started_at" "$daemon_supervisor"

  # Clean teardown on SIGTERM / SIGINT (what `--stop` and `launchctl
  # unload` / `systemctl --user stop` send) AND on normal exit: drop the
  # pid file and the daemon liveness block so `status` doesn't report a
  # ghost. The flag stops the loop rather than dying mid-poll.
  daemon_stop=false
  cleanup_daemon() {
    rm -f "$pid_file" 2>/dev/null || true
    rm -f "$state_dir/${repo_hash}.sentinel.daemon.json" 2>/dev/null || true
  }
  trap 'daemon_stop=true' TERM INT
  trap 'cleanup_daemon' EXIT

  start_epoch=$(date +%s 2>/dev/null || echo 0)
  cur_interval="$interval"
  consecutive_fail=0
  # Backoff ceiling: never wait longer than 16x the base interval (or the
  # max-runtime, whichever is smaller) so a long outage can't stall the loop
  # past its own cap.
  max_interval=$(( interval * 16 ))
  (( max_interval > max_runtime )) && max_interval="$max_runtime"

  while ! $daemon_stop; do
    # Hard max-runtime cap — the orphan backstop. A forgotten daemon (or one
    # whose supervisor failed to reap it) self-terminates here.
    nowsec=$(date +%s 2>/dev/null || echo 0)
    if (( start_epoch > 0 )) && (( nowsec - start_epoch >= max_runtime )); then
      echo "[nyann sentinel] daemon reached --max-runtime (${max_runtime}s) — exiting cleanly" >&2
      break
    fi

    if poll_one_pass; then
      # Success resets the backoff window.
      consecutive_fail=0
      cur_interval="$interval"
    else
      # Every fetch failed — exponential backoff, capped. Resets on the next
      # successful pass. This stops a rate-limited / offline daemon from
      # hammering gh.
      consecutive_fail=$(( consecutive_fail + 1 ))
      cur_interval=$(( interval * (1 << consecutive_fail) ))
      (( cur_interval > max_interval )) && cur_interval="$max_interval"
      echo "[nyann sentinel] poll pass failed (${consecutive_fail}x) — backing off to ${cur_interval}s" >&2
    fi

    # Fan out any newly-queued notifications to configured channels (P9).
    deliver_notifications

    # Refresh the liveness timestamp so consumers can tell the daemon is
    # alive and roughly when it last polled.
    write_daemon_block "$daemon_started_at" "$daemon_supervisor"

    # Sleep in 1s slices so a SIGTERM breaks out promptly instead of waiting
    # out a long (possibly backed-off) interval.
    slept=0
    while (( slept < cur_interval )) && ! $daemon_stop; do
      sleep 1
      slept=$(( slept + 1 ))
    done
  done

  cleanup_daemon
  trap - EXIT
  echo "[nyann sentinel] daemon stopped for $repo" >&2
  exit 0
fi

# --- One-shot path ----------------------------------------------------------
# Resolve the PR list once and poll each PR a single time.
prs_to_poll=()
while IFS= read -r n; do
  [[ -n "$n" ]] && prs_to_poll+=("$n")
done < <( resolve_prs )

if (( ${#prs_to_poll[@]} == 0 )); then
  echo "[nyann sentinel] no open PRs to poll for $repo" >&2
  # Still flush any queued-but-undelivered notifications (P9) — a prior poll
  # may have left a backlog. notify-deliver dedups, so this never re-sends.
  deliver_notifications
  exit 0
fi

# Record PID for --stop semantics. One-shot mode doesn't truly daemonize,
# but a caller wrapping us in nohup gets the right PID file.
printf '%s\n' "$$" > "$pid_file" 2>/dev/null || true

for pr in "${prs_to_poll[@]}"; do
  poll_pr "$pr" || echo "[nyann sentinel] poll failed for PR #$pr" >&2
done

# Fan out any newly-queued notifications to configured channels (P9). No-op
# when no delivery channel is configured.
deliver_notifications

# One-shot: clean up PID file.
rm -f "$pid_file" 2>/dev/null || true
