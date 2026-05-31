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

# Default mode: atomic read-and-truncate. Rename the queue to a sibling
# `.reading` file FIRST so any sentinel append between read and truncate
# lands in a freshly-created queue file (preserved for the next read)
# rather than being silently dropped. mv is atomic on the same filesystem.
reading_file="${notif_file}.reading.$$"
if mv "$notif_file" "$reading_file" 2>/dev/null; then
  if [[ -s "$reading_file" ]]; then
    jq -s '.' "$reading_file" 2>/dev/null || echo "[]"
  else
    echo "[]"
  fi
  rm -f "$reading_file"
else
  # Concurrent reader took it first, or filesystem hiccup. Either way,
  # nothing to deliver this call.
  echo "[]"
fi
