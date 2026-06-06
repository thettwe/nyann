#!/usr/bin/env bash
# read-notifications.sh — read and clear the notification queue for a repo.
#
# Usage:
#   read-notifications.sh --repo <owner/repo> [--notif-dir <dir>] [--peek]
#
# Default: reads all unread notifications, emits a JSON array, then
# truncates the file. With --peek, prints without truncating.
#
# Designed to be called by the session-start triage hook so users see PR
# state changes from prior sessions when they reopen Claude Code.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

repo=""
notif_dir="${HOME}/.claude/nyann/notifications"
peek=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        repo="${2-}"; shift 2 ;;
    --repo=*)      repo="${1#--repo=}"; shift ;;
    --notif-dir)   notif_dir="${2-}"; shift 2 ;;
    --notif-dir=*) notif_dir="${1#--notif-dir=}"; shift ;;
    --peek)        peek=true; shift ;;
    -h|--help)     sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || nyann::die "--repo <owner/repo> is required"

repo_hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12)
notif_file="$notif_dir/${repo_hash}.jsonl"

if [[ ! -f "$notif_file" ]]; then
  echo "[]"
  exit 0
fi

# --peek mode: read but do not truncate. No race concerns; the queue stays
# intact so any concurrent sentinel append is preserved.
if $peek; then
  if [[ -s "$notif_file" ]]; then
    jq -s '.' "$notif_file" 2>/dev/null || echo "[]"
  else
    echo "[]"
  fi
  exit 0
fi

# Default mode: read-and-truncate under the shared notifications lock so a
# concurrent sentinel append can't land in the moved inode and then be
# rm'd (the mv-then-rm alone is NOT atomic against a writer whose fd was
# opened before the mv — see ci-sentinel.sh append_notification, which
# holds the SAME lock). The lock name is derived from the queue path so
# both sides agree. Hold time is kept minimal: lock → mv → read → rm →
# unlock. mv is atomic on the same filesystem; the lock closes the
# residual window against writers.
lock_dir="${notif_file}.lock"
reading_file="${notif_file}.reading.$$"
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
