#!/usr/bin/env bash
# ci-sentinel.sh — poll one or all open PRs on a repo for state changes
# and emit Notification entries when state transitions occur.
#
# Usage:
#   ci-sentinel.sh --repo <owner/repo> [--pr <number>]
#                  [--interval <seconds>] [--max-runtime <seconds>]
#                  [--one-shot] [--state-dir <dir>] [--notif-dir <dir>]
#                  [--stop]
#
# Modes:
#   default       — single poll cycle (caller wraps in `nohup` or a launchd
#                   plist for backgrounded runs).
#   --one-shot    — explicit; same as default. Surfaced for clarity.
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
# shellcheck disable=SC2034  # reserved for the future daemonized poll loop; currently one-shot only.
interval=120
# shellcheck disable=SC2034  # reserved for the future daemonized poll loop.
max_runtime=14400
# shellcheck disable=SC2034  # always-true sentinel for one-shot mode; reserved for the daemonize toggle.
one_shot=true
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
    --state-dir)   state_dir="${2-}"; shift 2 ;;
    --state-dir=*) state_dir="${1#--state-dir=}"; shift ;;
    --notif-dir)   notif_dir="${2-}"; shift 2 ;;
    --notif-dir=*) notif_dir="${1#--notif-dir=}"; shift ;;
    --stop)        stop_mode=true; shift ;;
    -h|--help)     sed -n '3,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
# Touch interval / max_runtime / one_shot so shellcheck sees them consumed.
# They are part of the public CLI contract; the future daemonize wrapper
# will read them — keeping them parsed today avoids a breaking CLI change
# later.
: "$interval" "$max_runtime" "$one_shot"
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

# Resolve PR list — either the explicit --pr or all open PRs on the repo.
prs_to_poll=()
if [[ -n "$pr_filter" ]]; then
  prs_to_poll=("$pr_filter")
else
  while IFS= read -r n; do
    [[ -n "$n" ]] && prs_to_poll+=("$n")
  done < <( gh pr list --repo "$repo" --state open --json number --jq '.[].number' 2>/dev/null )
fi

if (( ${#prs_to_poll[@]} == 0 )); then
  echo "[nyann sentinel] no open PRs to poll for $repo" >&2
  exit 0
fi

# Record PID for --stop semantics. One-shot mode doesn't truly daemonize,
# but a caller wrapping us in nohup gets the right PID file.
printf '%s\n' "$$" > "$pid_file" 2>/dev/null || true

for pr in "${prs_to_poll[@]}"; do
  poll_pr "$pr" || echo "[nyann sentinel] poll failed for PR #$pr" >&2
done

# One-shot: clean up PID file. Long-running daemon would loop on $interval
# until $max_runtime expires, but that's a follow-up wrapper.
rm -f "$pid_file" 2>/dev/null || true
