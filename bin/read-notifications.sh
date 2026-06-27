#!/usr/bin/env bash
# read-notifications.sh — read and clear the notification queue for a repo.
#
# Usage:
#   read-notifications.sh --repo <owner/repo> [--notif-dir <dir>] [--peek]
#   read-notifications.sh --all [--watch-list <path>] [--notif-dir <dir>] [--peek]
#
# Default: reads all unread notifications, emits a JSON array, then
# truncates the file. With --peek, prints without truncating.
#
# With --all, resolves every repo from the watch-list
# (~/.claude/nyann/watch-list.json), drains each per-repo queue, and emits a
# single repo-tagged array: each entry gains `context.repo = <owner/repo>` so
# the aggregated view distinguishes which repo a notification came from. The
# per-repo locked drain semantics are identical to single-repo mode. --peek
# composes with --all (peek every queue, truncate none).
#
# Designed to be called by the session-start triage hook so users see PR
# state changes from prior sessions when they reopen Claude Code.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

repo=""
notif_dir="${HOME}/.claude/nyann/notifications"
watch_list="${HOME}/.claude/nyann/watch-list.json"
peek=false
all=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        repo="${2-}"; shift 2 ;;
    --repo=*)      repo="${1#--repo=}"; shift ;;
    --all)         all=true; shift ;;
    --watch-list)   watch_list="${2-}"; shift 2 ;;
    --watch-list=*) watch_list="${1#--watch-list=}"; shift ;;
    --notif-dir)   notif_dir="${2-}"; shift 2 ;;
    --notif-dir=*) notif_dir="${1#--notif-dir=}"; shift ;;
    --peek)        peek=true; shift ;;
    -h|--help)     sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# repo_hash <slug> — MUST match ci-sentinel.sh / sentinel-aggregate.sh exactly
# so the queue files line up across writers and readers.
repo_hash() {
  printf '%s' "$1" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12
}

# drain_repo <repo> — print the JSON array of queued notifications for <repo>.
# Honours the global $peek (peek = read without truncating). The
# read-and-truncate path runs under the shared notifications lock so a
# concurrent sentinel append can't land in the moved inode and then be rm'd
# (the mv-then-rm alone is NOT atomic against a writer whose fd was opened
# before the mv — see ci-sentinel.sh append_notification, which holds the SAME
# lock). The lock name is derived from the queue path so both sides agree.
# Hold time is kept minimal: lock -> mv -> read -> rm -> unlock. mv is atomic
# on the same filesystem; the lock closes the residual window against writers.
drain_repo() {
  local r="$1"
  local rh notif_file
  rh="$(repo_hash "$r")"
  notif_file="$notif_dir/${rh}.jsonl"

  if [[ ! -f "$notif_file" ]]; then
    echo "[]"
    return 0
  fi

  # --peek mode: read but do not truncate. No race concerns; the queue stays
  # intact so any concurrent sentinel append is preserved.
  if $peek; then
    if [[ -s "$notif_file" ]]; then
      jq -s '.' "$notif_file" 2>/dev/null || echo "[]"
    else
      echo "[]"
    fi
    return 0
  fi

  local lock_dir="${notif_file}.lock"
  local reading_file="${notif_file}.reading.$$"
  nyann::lock "$lock_dir"
  if mv "$notif_file" "$reading_file" 2>/dev/null; then
    # A crash between here and the rm -f would strand the queue in
    # reading_file forever. Install an EXIT trap so an interrupted reader
    # still cleans up; the explicit rm -f below makes the trap a no-op on
    # the happy path (rm -f is idempotent). The trap also frees the lock.
    trap 'rm -f "$reading_file"; nyann::unlock "$lock_dir"' EXIT
    if [[ -s "$reading_file" ]]; then
      # Capture jq's output AND exit status BEFORE deleting anything: a
      # partial/corrupt NDJSON line from a crashed writer makes jq fail,
      # and `|| echo "[]"` would otherwise mask the failure and we'd rm
      # the only copy of the data. On failure, preserve the queue to a
      # `.corrupt.$$` sibling (do NOT rm) so it can be recovered.
      local out
      if out=$(jq -s '.' "$reading_file" 2>/dev/null); then
        printf '%s\n' "$out"
        rm -f "$reading_file"
      else
        mv "$reading_file" "${notif_file}.corrupt.$$" 2>/dev/null || true
        nyann::warn "notification queue unparseable (crashed writer?) — preserved to ${notif_file}.corrupt.$$; delivering nothing this call"
        echo "[]"
      fi
    else
      echo "[]"
      rm -f "$reading_file"
    fi
    nyann::unlock "$lock_dir"
    trap - EXIT
  else
    # Concurrent reader took it first, or filesystem hiccup. Either way,
    # nothing to deliver this call.
    nyann::unlock "$lock_dir"
    echo "[]"
  fi
  return 0
}

if $all; then
  # Aggregated read: resolve repos from the watch-list, drain each queue, tag
  # every entry with context.repo, and merge into one array. An absent or
  # empty watch-list is a clean no-op ([]).
  if [[ ! -f "$watch_list" ]]; then
    echo "[]"
    exit 0
  fi
  repos=()
  while IFS= read -r r; do
    [[ -n "$r" ]] && repos+=("$r")
  done < <(jq -r '.[]?.repo // empty' "$watch_list" 2>/dev/null || true)

  if (( ${#repos[@]} == 0 )); then
    echo "[]"
    exit 0
  fi

  merged="[]"
  for r in "${repos[@]}"; do
    arr="$(drain_repo "$r")" || arr="[]"
    # Tag each entry via the context object — the Notification schema allows
    # additional context props, so this never breaks notification validation
    # (the top-level object stays additionalProperties:false / repo-free).
    tagged="$(jq --arg r "$r" 'map(.context = ((.context // {}) + {repo: $r}))' <<<"$arr" 2>/dev/null || echo "[]")"
    merged="$(jq -s 'add // []' <<<"${merged}"$'\n'"${tagged}" 2>/dev/null || printf '%s' "$merged")"
  done
  printf '%s\n' "$merged"
  exit 0
fi

[[ -n "$repo" ]] || nyann::die "--repo <owner/repo> is required (or use --all)"
drain_repo "$repo"
