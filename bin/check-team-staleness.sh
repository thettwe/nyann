#!/usr/bin/env bash
# check-team-staleness.sh — notify when team profiles have upstream changes.
#
# Usage: check-team-staleness.sh [--user-root <dir>]
#
# Wraps bin/check-team-drift.sh and emits human-readable notification
# lines to stdout for each stale team source. Exits silently when:
#   - no team sources configured
#   - all sources are up to date
#   - any dependency is missing
#
# Designed to run as a background monitor — must never block, never
# prompt, never write to the filesystem.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! source "${_script_dir}/_lib.sh" 2>/dev/null; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    *) shift ;;
  esac
done

config="$user_root/config.json"
[[ -f "$config" ]] || exit 0

# Check if any team sources exist.
n_sources=$(jq '.team_profile_sources // [] | length' "$config" 2>/dev/null) || exit 0
(( n_sources == 0 )) && exit 0

# Run the drift checker (online mode). Suppress all errors.
report=$("${_script_dir}/check-team-drift.sh" --user-root "$user_root" 2>/dev/null) || exit 0
[[ -n "$report" ]] || exit 0

n_drift=$(jq '.drift | length' <<<"$report" 2>/dev/null) || exit 0
n_unreachable=$(jq '.unreachable | length' <<<"$report" 2>/dev/null) || exit 0

(( n_drift == 0 && n_unreachable == 0 )) && exit 0

# Emit notification lines.
if (( n_drift > 0 )); then
  profiles=$(jq -r '[.drift[].namespaced] | join(", ")' <<<"$report" 2>/dev/null)
  echo "[nyann] ${n_drift} team profile(s) have upstream changes: ${profiles}. Run /nyann:sync-team-profiles to update."
fi

if (( n_unreachable > 0 )); then
  sources=$(jq -r '[.unreachable[].source] | unique | join(", ")' <<<"$report" 2>/dev/null)
  echo "[nyann] ${n_unreachable} team source(s) unreachable: ${sources}. Check network or source config."
fi
