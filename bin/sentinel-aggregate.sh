#!/usr/bin/env bash
# sentinel-aggregate.sh — multi-repo CI sentinel aggregation.
#
# Manages a watch-list of repos and drives one-shot ci-sentinel polls
# across all of them under a single, GLOBALLY rate-limit-aware scheduler.
# Notifications land in the same per-repo queues ci-sentinel writes; the
# unified, repo-tagged read is `read-notifications.sh --all`.
#
# Usage:
#   sentinel-aggregate.sh --add <owner/repo> [--pr <N>]
#   sentinel-aggregate.sh --remove <owner/repo>
#   sentinel-aggregate.sh --list
#   sentinel-aggregate.sh --poll [--interval <s>] [--max-interval <s>]
#                                [--rate-reserve <n>]
#   sentinel-aggregate.sh --daemon-loop [--interval <s>] [--max-runtime <s>]
#                                [--supervisor <name>]
#   sentinel-aggregate.sh --stop
#
# Shared options (all modes):
#   --watch-list <path>   watch-list JSON (default: ~/.claude/nyann/watch-list.json)
#   --state-dir <dir>     sentinel + scheduler state (default: ~/.claude/nyann/cache)
#   --notif-dir <dir>     notification queues (default: ~/.claude/nyann/notifications)
#   --sentinel <path>     ci-sentinel.sh to invoke (default: alongside this script)
#
# Modes:
#   --add     Idempotently add <owner/repo> to the watch-list. With --pr,
#             merge that PR number into the entry's prs[] (deduped). Re-adding
#             an existing repo never creates a duplicate.
#   --remove  Remove <owner/repo> from the watch-list (no-op if absent).
#   --list    Print the watch-list as a JSON array (empty list = []).
#   --poll    Iterate the watch-list and run ci-sentinel one-shot per repo.
#             A single scheduler tracks the GitHub core rate budget and backs
#             off GLOBALLY (adaptive interval, all repos) when the budget is
#             low — so N repos x M PRs can't blow the 5000/hr ceiling. Prints
#             a scheduler-summary JSON to stdout and persists it to
#             <state-dir>/aggregate-scheduler.json.
#   --daemon-loop  Supervised long-running mode (v1.13.0 P10). Runs one --poll
#             cycle, then sleeps the scheduler's `current_interval` and repeats
#             until --max-runtime (default 8h) or a SIGTERM/SIGINT arrives. The
#             per-cycle scheduler already backs off globally, so the loop just
#             honours its cadence — no second backoff layer here. There is ONE
#             aggregate daemon per user, so it uses FIXED file names (not
#             repo-hashed): aggregate.sentinel.pid + aggregate.sentinel.daemon
#             .json. Refuses to start if a live aggregate daemon already owns
#             those files (single-instance). Normally launched by
#             bin/sentinel-daemon.sh under launchd / systemd / nohup.
#   --stop    Kill the running aggregate daemon via aggregate.sentinel.pid
#             (PID-reuse guarded) and reap the pid + liveness block.
#
#   --max-runtime <s>  daemon-loop orphan backstop in seconds (default 28800/8h).
#   --supervisor <n>   record which supervisor launched the loop (launchd|systemd
#             |nohup) into the daemon liveness block. Advisory.
#
# Standalone by design: a supervising daemon wires aggregate mode by calling
# `sentinel-aggregate.sh --poll` on its own cadence and honouring the
# `current_interval` field of the summary for the next sleep — which is exactly
# what --daemon-loop does in-process.
#
# Requires jq. gh is best-effort: missing gh soft-skips the poll.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

mode=""
repo=""
pr=""
watch_list="${HOME}/.claude/nyann/watch-list.json"
state_dir="${HOME}/.claude/nyann/cache"
notif_dir="${HOME}/.claude/nyann/notifications"
sentinel="${_script_dir}/ci-sentinel.sh"
base_interval=120
max_interval=1800
rate_reserve=100
# Default hard cap is 8h (28800s) for the daemon loop — the orphan backstop,
# matching ci-sentinel.sh. Non-daemon modes never read it.
max_runtime=28800
supervisor=""

set_mode() {
  [[ -z "$mode" ]] || nyann::die "only one of --add / --remove / --list / --poll / --daemon-loop / --stop may be given"
  mode="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)           set_mode add; repo="${2-}"; shift 2 ;;
    --add=*)         set_mode add; repo="${1#--add=}"; shift ;;
    --remove)        set_mode remove; repo="${2-}"; shift 2 ;;
    --remove=*)      set_mode remove; repo="${1#--remove=}"; shift ;;
    --list)          set_mode list; shift ;;
    --poll)          set_mode poll; shift ;;
    --daemon-loop)   set_mode daemon-loop; shift ;;
    --stop)          set_mode stop; shift ;;
    --pr)            pr="${2-}"; shift 2 ;;
    --pr=*)          pr="${1#--pr=}"; shift ;;
    --watch-list)    watch_list="${2-}"; shift 2 ;;
    --watch-list=*)  watch_list="${1#--watch-list=}"; shift ;;
    --state-dir)     state_dir="${2-}"; shift 2 ;;
    --state-dir=*)   state_dir="${1#--state-dir=}"; shift ;;
    --notif-dir)     notif_dir="${2-}"; shift 2 ;;
    --notif-dir=*)   notif_dir="${1#--notif-dir=}"; shift ;;
    --sentinel)      sentinel="${2-}"; shift 2 ;;
    --sentinel=*)    sentinel="${1#--sentinel=}"; shift ;;
    --interval)      base_interval="${2-}"; shift 2 ;;
    --interval=*)    base_interval="${1#--interval=}"; shift ;;
    --max-interval)  max_interval="${2-}"; shift 2 ;;
    --max-interval=*) max_interval="${1#--max-interval=}"; shift ;;
    --rate-reserve)  rate_reserve="${2-}"; shift 2 ;;
    --rate-reserve=*) rate_reserve="${1#--rate-reserve=}"; shift ;;
    --max-runtime)   max_runtime="${2-}"; shift 2 ;;
    --max-runtime=*) max_runtime="${1#--max-runtime=}"; shift ;;
    --supervisor)    supervisor="${2-}"; shift 2 ;;
    --supervisor=*)  supervisor="${1#--supervisor=}"; shift ;;
    -h|--help)       sed -n '3,59p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$mode" ]] || nyann::die "one of --add / --remove / --list / --poll / --daemon-loop / --stop is required"

# In daemon-loop mode the interval + max-runtime are live inputs — validate them
# so a typo can't put the loop into a tight no-sleep spin or an unbounded run
# (the orphan backstop depends on a sane cap). Mirrors ci-sentinel.sh.
if [[ "$mode" == "daemon-loop" ]]; then
  if ! [[ "$base_interval" =~ ^[0-9]+$ ]] || (( base_interval < 1 )); then
    nyann::die "--interval must be a positive integer of seconds (got: $base_interval)"
  fi
  if ! [[ "$max_runtime" =~ ^[0-9]+$ ]] || (( max_runtime < 1 )); then
    nyann::die "--max-runtime must be a positive integer of seconds (got: $max_runtime)"
  fi
  # The scheduler tunables are consumed every cycle by run_poll_cycle; a bad
  # value would only surface (fatally) deep in the first cycle. Fail fast at
  # start instead so a typo can't take the whole daemon down mid-run.
  # --max-interval must be a POSITIVE integer (>= 1): a 0 makes a backoff cycle
  # clamp the adaptive interval to 0, and the 1s-slice sleep then never sleeps →
  # a tight re-poll busy-spin. An explicitly non-numeric value still errors.
  if ! [[ "$max_interval" =~ ^[0-9]+$ ]] || (( max_interval < 1 )); then
    nyann::die "--max-interval must be a positive integer of seconds (got: $max_interval)"
  fi
  # A --max-interval below --interval just means there is no room to back off
  # past the base cadence — clamp the ceiling UP to --interval rather than
  # dying. sentinel-daemon.sh forwards only --interval to this daemon (not
  # --max-interval), so a large --interval (e.g. hourly polling) would otherwise
  # hit the default max_interval=1800 and silently abort the daemon behind a
  # "started" message. Mirrors ci-sentinel.sh deriving its own ceiling from the
  # interval (max_interval=interval*16).
  (( max_interval < base_interval )) && max_interval="$base_interval"
  if ! [[ "$rate_reserve" =~ ^[0-9]+$ ]]; then
    nyann::die "--rate-reserve must be a non-negative integer (got: $rate_reserve)"
  fi
  case "${supervisor:-nohup}" in
    launchd|systemd|nohup|"") ;;
    *) nyann::die "--supervisor must be one of launchd|systemd|nohup (got: $supervisor)" ;;
  esac
fi

# --- Validation helpers -------------------------------------------------------

# valid_repo_slug <slug> — accept only <owner>/<repo> shape. Reject a leading
# `-` (option injection into gh / ci-sentinel) and any `.`/`..` path component
# (defensive: keeps a hand-edited watch-list from smuggling traversal even
# though the slug is only ever md5-hashed, never used as a path).
valid_repo_slug() {
  local r="${1-}"
  [[ -n "$r" ]] || return 1
  [[ "$r" != -* ]] || return 1
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  case "$r" in
    .|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
  esac
  return 0
}

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# repo_hash <slug> — MUST match ci-sentinel.sh / read-notifications.sh exactly
# so the queue/state files line up across all three callers.
repo_hash() {
  printf '%s' "$1" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12
}

# read_watch_list — print the current watch-list array (or [] if absent).
read_watch_list() {
  if [[ -f "$watch_list" ]]; then
    jq -e '.' "$watch_list" 2>/dev/null || echo "[]"
  else
    echo "[]"
  fi
}

# write_watch_list <json> — atomically replace the watch-list under a lock.
write_watch_list() {
  local json="$1"
  local dir; dir="$(dirname "$watch_list")"
  mkdir -p "$dir" 2>/dev/null || true
  local lock="${watch_list}.lock"
  local tmp="${watch_list}.tmp.$$"
  nyann::lock "$lock"
  trap 'rm -f "$tmp"; nyann::unlock "$lock"' EXIT
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$watch_list"
  nyann::unlock "$lock"
  trap - EXIT
}

# --- Poll cycle ---------------------------------------------------------------

# run_poll_cycle — run ONE aggregate poll cycle and print the scheduler-summary
# JSON to stdout (also persisting it to <state-dir>/aggregate-scheduler.json).
# Extracted verbatim from the original --poll body so both --poll (one cycle)
# and --daemon-loop (repeat) share a single implementation. The per-cycle
# scheduler lock is acquired and released INSIDE this function — never held
# across a sleep — so a daemon-loop caller can sleep between cycles safely.
run_poll_cycle() {
    # Validate numeric tunables up front so a bad value can't silently
    # disable backoff or corrupt the scheduler arithmetic.
    for n in base_interval max_interval rate_reserve; do
      v="${!n}"
      [[ "$v" =~ ^[0-9]+$ ]] || nyann::die "--${n//_/-} must be a non-negative integer (got: $v)"
    done

    current="$(read_watch_list)"
    # Resolve repos, skipping (with a warning) any malformed slug a hand-edit
    # may have introduced — a bad entry must not abort the whole cycle.
    repos=()
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      if valid_repo_slug "$r"; then
        repos+=("$r")
      else
        nyann::warn "watch-list: skipping malformed repo entry: $r"
      fi
    done < <(jq -r '.[]?.repo // empty' <<<"$current" 2>/dev/null || true)

    mkdir -p "$state_dir" "$notif_dir" 2>/dev/null || true
    sched_file="$state_dir/aggregate-scheduler.json"

    emit_summary() {
      # $1=backoff(bool) $2=remaining(int|"") $3=interval $4=consec
      #   $5=polled_json $6=skipped_json
      jq -n \
        --arg ts "$(now)" \
        --argjson backoff "$1" \
        --arg remaining "$2" \
        --argjson base "$base_interval" \
        --argjson interval "$3" \
        --argjson consec "$4" \
        --argjson polled "$5" \
        --argjson skipped "$6" \
        '{
          last_run_at: $ts,
          backoff: $backoff,
          rate_remaining: (if $remaining == "" then null else ($remaining|tonumber) end),
          base_interval: $base,
          current_interval: $interval,
          consecutive_backoffs: $consec,
          polled: $polled,
          skipped: $skipped
        }'
    }

    # Empty watch-list = clean no-op (still emit a summary so the daemon has a
    # stable contract to parse).
    if (( ${#repos[@]} == 0 )); then
      nyann::log "watch-list empty — nothing to poll"
      summary="$(emit_summary false "" "$base_interval" 0 '[]' '[]')"
      printf '%s\n' "$summary" > "$sched_file" 2>/dev/null || true
      printf '%s\n' "$summary"
      return 0
    fi

    # gh is the rate-budget oracle AND what ci-sentinel needs — without it the
    # whole poll is a no-op, so soft-skip early (parity with ci-sentinel).
    if ! nyann::has_cmd gh; then
      nyann::log "gh CLI not installed — skipping poll"
      summary="$(emit_summary false "" "$base_interval" 0 '[]' '[]')"
      printf '%s\n' "$summary" > "$sched_file" 2>/dev/null || true
      printf '%s\n' "$summary"
      return 0
    fi

    # Serialize the scheduler so two aggregate polls can't double-spend budget.
    sched_lock="$state_dir/aggregate-scheduler.lock"
    nyann::lock "$sched_lock"
    trap 'nyann::unlock "$sched_lock"' EXIT

    # Carry forward the adaptive interval / consecutive-backoff counter.
    prev_consec=0
    if [[ -f "$sched_file" ]]; then
      prev_consec="$(jq -r '.consecutive_backoffs // 0' "$sched_file" 2>/dev/null || echo 0)"
      [[ "$prev_consec" =~ ^[0-9]+$ ]] || prev_consec=0
    fi

    # Read the GitHub core rate budget (best-effort: unknown => proceed).
    remaining=""
    raw_remaining="$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || true)"
    [[ "$raw_remaining" =~ ^[0-9]+$ ]] && remaining="$raw_remaining"

    backoff=false
    # Pre-flight global backoff: if the budget is already under the reserve,
    # do NOT poll any repo. ONE scheduler decision covers every repo (the
    # v1.12.0 P3 mitigation: back off globally, not per-repo) so a fleet of
    # repos can't each independently burn the last of the budget.
    if [[ -n "$remaining" ]] && (( remaining < rate_reserve )); then
      backoff=true
    fi

    polled=()
    skipped=()
    if $backoff; then
      skipped=("${repos[@]}")
    else
      # In-loop budget guard: decrement an estimate as we go and, if we'd
      # cross the reserve mid-cycle, stop the WHOLE scheduler (skip the
      # remaining repos) rather than letting later repos overrun the budget.
      est_remaining="$remaining"
      for r in "${repos[@]}"; do
        # Don't double-watch a repo that already has its OWN live per-repo
        # daemon: that daemon polls AND delivers for the repo independently, so
        # aggregating it too would post duplicate notifications (e.g. a Slack
        # message twice). Keep exactly one producer per repo — skip it here.
        # Reuse repo_hash + the same kill -0 / ps-cmdline liveness guard used by
        # run_stop / the single-instance guard; a stale or dead pid file does
        # NOT skip (only a live *ci-sentinel* process counts).
        repo_pid_file="$state_dir/$(repo_hash "$r").sentinel.pid"
        if [[ -f "$repo_pid_file" ]]; then
          repo_pid=$(cat "$repo_pid_file" 2>/dev/null || true)
          if [[ -n "$repo_pid" ]] && kill -0 "$repo_pid" 2>/dev/null; then
            repo_pid_cmd=$(ps -p "$repo_pid" -o command= 2>/dev/null || ps -p "$repo_pid" -o comm= 2>/dev/null || true)
            if [[ "$repo_pid_cmd" == *ci-sentinel* ]]; then
              nyann::warn "skipping $r — a live per-repo daemon (pid $repo_pid) already covers it"
              skipped+=("$r")
              continue
            fi
          fi
        fi
        if [[ -n "$est_remaining" ]] && (( est_remaining < rate_reserve )); then
          backoff=true
          skipped+=("$r")
          continue
        fi
        # Per-repo PR set (explicit prs[] or "all open" when empty).
        prs=()
        while IFS= read -r n; do
          [[ -n "$n" ]] && prs+=("$n")
        done < <(jq -r --arg r "$r" '.[]? | select(.repo == $r) | (.prs // [])[]' <<<"$current" 2>/dev/null || true)

        if (( ${#prs[@]} > 0 )); then
          for n in "${prs[@]}"; do
            bash "$sentinel" --repo "$r" --pr "$n" --one-shot \
              --state-dir "$state_dir" --notif-dir "$notif_dir" \
              || nyann::warn "sentinel poll failed for $r PR #$n"
            [[ -n "$est_remaining" ]] && est_remaining=$((est_remaining - 1))
          done
        else
          bash "$sentinel" --repo "$r" --one-shot \
            --state-dir "$state_dir" --notif-dir "$notif_dir" \
            || nyann::warn "sentinel poll failed for $r"
          # "all open PRs" costs 1 list call + up to a handful of views; charge
          # a small fixed estimate so a wide fan-out still trips the guard.
          [[ -n "$est_remaining" ]] && est_remaining=$((est_remaining - 5))
        fi
        polled+=("$r")
      done
    fi

    # Adaptive interval: double per consecutive backoff (capped); reset to base
    # on a clean cycle.
    if $backoff; then
      consec=$((prev_consec + 1))
      interval="$base_interval"
      i=0
      # Clamp INSIDE the loop: doubling unboundedly before the post-loop cap
      # could integer-overflow on a long backoff streak. Break the moment we
      # reach the ceiling.
      while (( i < consec )); do
        interval=$((interval * 2))
        (( interval >= max_interval )) && { interval="$max_interval"; break; }
        i=$((i + 1))
      done
      (( interval > max_interval )) && interval="$max_interval"
      nyann::warn "rate budget low (remaining=${remaining:-unknown}, reserve=$rate_reserve) — global backoff; next interval=${interval}s"
    else
      consec=0
      interval="$base_interval"
    fi

    polled_json="$(printf '%s\n' "${polled[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')"
    skipped_json="$(printf '%s\n' "${skipped[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')"

    summary="$(emit_summary "$backoff" "$remaining" "$interval" "$consec" "$polled_json" "$skipped_json")"
    printf '%s\n' "$summary" > "$sched_file" 2>/dev/null || true

    nyann::unlock "$sched_lock"
    trap - EXIT

    printf '%s\n' "$summary"
    return 0
}

# --- Daemon supervision (v1.13.0 P10) ----------------------------------------

# There is ONE aggregate daemon per user, so the pid + liveness files use FIXED
# names (not repo-hashed) — the per-repo daemon uses <repo-hash>.sentinel.*.
agg_pid_file="$state_dir/aggregate.sentinel.pid"
agg_daemon_file="$state_dir/aggregate.sentinel.daemon.json"

# write_aggregate_daemon_block — record the aggregate daemon's liveness as a
# SentinelState `daemon` block (schema-additive). repo is the reserved
# "(aggregate)" sentinel and pr_number 0 marks it as a daemon-liveness record
# rather than real PR state — mirrors ci-sentinel.sh's per-repo block. Lives at
# a fixed path so doctor / status / report can surface "aggregate daemon alive".
# Best-effort: a failed write never aborts the loop.
write_aggregate_daemon_block() {
  local started_at="$1" sup="$2"
  jq -n \
    --arg ts "$(now)" \
    --argjson pid "$$" \
    --arg started "$started_at" \
    --arg sup "$sup" \
    '{repo:"(aggregate)", pr_number:0, last_poll_at:$ts, checks_status:"unknown", review_status:"unknown",
      daemon: {pid:$pid, started_at:$started, supervisor:$sup}}' \
    > "$agg_daemon_file" 2>/dev/null || true
}

# run_daemon_loop — supervised long-running aggregate poller. Mirrors
# ci-sentinel.sh's --daemon-loop block: single-instance guard, pid file,
# TERM/INT-driven clean teardown, 1s-slice sleeps so a SIGTERM breaks out
# promptly, and a --max-runtime orphan backstop. The per-cycle scheduler in
# run_poll_cycle already backs off globally, so the loop simply honours its
# `current_interval` for the next sleep — no second backoff layer here.
run_daemon_loop() {
  mkdir -p "$state_dir" "$notif_dir" 2>/dev/null || true

  # --- Single-instance guard ------------------------------------------------
  # Refuse to start a second aggregate daemon. A live process whose cmdline
  # still looks like sentinel-aggregate owns the daemon; a stale pid (dead /
  # recycled) is reclaimed silently.
  if [[ -f "$agg_pid_file" ]]; then
    local existing existing_cmd
    existing=$(cat "$agg_pid_file" 2>/dev/null || true)
    if [[ -n "$existing" ]] && kill -0 "$existing" 2>/dev/null; then
      existing_cmd=$(ps -p "$existing" -o command= 2>/dev/null || ps -p "$existing" -o comm= 2>/dev/null || true)
      if [[ "$existing_cmd" == *sentinel-aggregate* ]]; then
        echo "[nyann sentinel] aggregate daemon already running (pid $existing) — not starting a second" >&2
        return 0
      fi
    fi
    # Stale pid file — reclaim it.
    rm -f "$agg_pid_file" 2>/dev/null || true
  fi

  printf '%s\n' "$$" > "$agg_pid_file" 2>/dev/null || true

  local daemon_started_at daemon_supervisor
  daemon_started_at="$(now)"
  daemon_supervisor="${supervisor:-nohup}"
  write_aggregate_daemon_block "$daemon_started_at" "$daemon_supervisor"

  # Clean teardown on SIGTERM / SIGINT (what `--stop` and `launchctl bootout`
  # / `systemctl --user stop` send) AND on normal exit: drop the pid file and
  # the liveness block so status/report don't report a ghost. The flag stops
  # the loop rather than dying mid-poll.
  agg_daemon_stop=false
  cleanup_aggregate_daemon() {
    rm -f "$agg_pid_file" 2>/dev/null || true
    rm -f "$agg_daemon_file" 2>/dev/null || true
  }
  trap 'agg_daemon_stop=true' TERM INT
  trap 'cleanup_aggregate_daemon' EXIT

  local start_epoch nowsec summary next_interval slept
  start_epoch=$(date +%s 2>/dev/null || echo 0)

  while ! $agg_daemon_stop; do
    # Hard max-runtime cap — the orphan backstop. A forgotten daemon (or one
    # whose supervisor failed to reap it) self-terminates here.
    nowsec=$(date +%s 2>/dev/null || echo 0)
    if (( start_epoch > 0 )) && (( nowsec - start_epoch >= max_runtime )); then
      echo "[nyann sentinel] aggregate daemon reached --max-runtime (${max_runtime}s) — exiting cleanly" >&2
      break
    fi

    # One scheduler cycle. Captured in a subshell so we can parse the summary;
    # the per-cycle scheduler lock lives and dies inside run_poll_cycle.
    # `|| summary=""` is LOAD-BEARING: under `set -o errexit`, a non-zero
    # run_poll_cycle (transient lock timeout, gh hiccup) in a command-
    # substitution assignment would otherwise abort the whole daemon — killing
    # the documented transient-failure fallback below. Swallow it and fall
    # back to the base cadence so the loop keeps running.
    summary="$(run_poll_cycle)" || summary=""
    next_interval="$(printf '%s' "$summary" | jq -r '.current_interval // empty' 2>/dev/null || true)"
    # Fall back to the base interval if the summary couldn't be parsed (e.g. a
    # transient lock-timeout) so the loop never busy-spins.
    [[ "$next_interval" =~ ^[0-9]+$ ]] || next_interval="$base_interval"
    # Floor to >=1s so a degenerate 0 (e.g. an out-of-band scheduler state) can
    # never make the slice sleep spin without delay.
    if (( next_interval < 1 )); then next_interval=1; fi

    # Refresh the liveness timestamp so consumers can tell the daemon is alive
    # and roughly when it last polled.
    write_aggregate_daemon_block "$daemon_started_at" "$daemon_supervisor"

    # Sleep in 1s slices so a SIGTERM breaks out promptly instead of waiting
    # out a long (possibly backed-off) interval.
    slept=0
    while (( slept < next_interval )) && ! $agg_daemon_stop; do
      sleep 1
      slept=$(( slept + 1 ))
    done
  done

  cleanup_aggregate_daemon
  trap - EXIT
  echo "[nyann sentinel] aggregate daemon stopped" >&2
  return 0
}

# run_stop — PID-reuse-guarded kill of the aggregate daemon, then reap the pid
# file + liveness block. Clean no-op when nothing is running.
run_stop() {
  if [[ -f "$agg_pid_file" ]]; then
    local pid proc_cmd
    pid=$(cat "$agg_pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      # Guard against PID reuse: a crashed daemon can leave a stale pid file
      # whose number the OS later recycled for an unrelated process. Only kill
      # if the live process actually looks like sentinel-aggregate.
      proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
      if [[ "$proc_cmd" == *sentinel-aggregate* ]]; then
        kill "$pid" 2>/dev/null || true
        echo "[nyann sentinel] stopped aggregate daemon pid $pid"
      else
        echo "[nyann sentinel] pid $pid is not an aggregate sentinel (stale pid file) — not killing" >&2
      fi
    fi
    rm -f "$agg_pid_file" 2>/dev/null || true
  fi
  rm -f "$agg_daemon_file" 2>/dev/null || true
  return 0
}

# --- Modes --------------------------------------------------------------------

case "$mode" in
  add)
    valid_repo_slug "$repo" || nyann::die "invalid repo (expected <owner>/<repo>): $repo"
    # Reject --pr 0 (and any non-positive / non-numeric): the watch-list schema
    # requires prs[] >= 1, so a 0 would write a file that fails validation.
    if [[ -n "$pr" ]] && ! [[ "$pr" =~ ^[1-9][0-9]*$ ]]; then
      nyann::die "--pr must be a positive integer (got: $pr)"
    fi
    current="$(read_watch_list)"
    if [[ -n "$pr" ]]; then
      updated="$(jq --arg r "$repo" --argjson p "$pr" '
        if any(.[]?; .repo == $r)
        then map(if .repo == $r then .prs = (((.prs // []) + [$p]) | unique) else . end)
        else . + [{repo: $r, prs: [$p]}] end
      ' <<<"$current")"
    else
      updated="$(jq --arg r "$repo" '
        if any(.[]?; .repo == $r) then . else . + [{repo: $r}] end
      ' <<<"$current")"
    fi
    write_watch_list "$updated"
    nyann::log "watch-list: added $repo${pr:+ (PR #$pr)}"
    ;;

  remove)
    valid_repo_slug "$repo" || nyann::die "invalid repo (expected <owner>/<repo>): $repo"
    current="$(read_watch_list)"
    updated="$(jq --arg r "$repo" 'map(select(.repo != $r))' <<<"$current")"
    write_watch_list "$updated"
    nyann::log "watch-list: removed $repo"
    ;;

  list)
    read_watch_list
    ;;

  poll)
    run_poll_cycle
    ;;

  daemon-loop)
    run_daemon_loop
    ;;

  stop)
    run_stop
    ;;
esac
