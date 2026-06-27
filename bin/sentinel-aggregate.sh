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
#
# Standalone by design: a supervising daemon wires aggregate mode by calling
# `sentinel-aggregate.sh --poll` on its own cadence and honouring the
# `current_interval` field of the summary for the next sleep.
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

set_mode() {
  [[ -z "$mode" ]] || nyann::die "only one of --add / --remove / --list / --poll may be given"
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
    -h|--help)       sed -n '3,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$mode" ]] || nyann::die "one of --add / --remove / --list / --poll is required"

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

# --- Modes --------------------------------------------------------------------

case "$mode" in
  add)
    valid_repo_slug "$repo" || nyann::die "invalid repo (expected <owner>/<repo>): $repo"
    if [[ -n "$pr" ]] && ! [[ "$pr" =~ ^[0-9]+$ ]]; then
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
      exit 0
    fi

    # gh is the rate-budget oracle AND what ci-sentinel needs — without it the
    # whole poll is a no-op, so soft-skip early (parity with ci-sentinel).
    if ! nyann::has_cmd gh; then
      nyann::log "gh CLI not installed — skipping poll"
      summary="$(emit_summary false "" "$base_interval" 0 '[]' '[]')"
      printf '%s\n' "$summary" > "$sched_file" 2>/dev/null || true
      printf '%s\n' "$summary"
      exit 0
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
      while (( i < consec )); do
        interval=$((interval * 2))
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
    ;;
esac
