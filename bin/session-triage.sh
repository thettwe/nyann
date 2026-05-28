#!/usr/bin/env bash
# session-triage.sh — UserPromptSubmit-hook wrapper for session-check.
#
# Quiet by default. Honors preferences.session_triage; if false, exits 0.
# Calls bin/session-check.sh --flow=session-start with a hard 2s timeout
# (when GNU/BSD timeout is available) so a slow git/jq probe can never
# block the user's first prompt. Any failure (missing deps, non-git dir,
# locked cache) exits silently.
#
# Usage:
#   bin/session-triage.sh                # used by hook (no args)
#   bin/session-triage.sh --target <dir> # used by tests
#
# Output: forwarded from session-check.sh — a single line or nothing.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers but don't crash if anything errors — the hook should
# never bubble up bash errors into the user's session.
if ! source "${_script_dir}/_lib.sh" 2>/dev/null; then
  exit 0
fi

# Disable strict mode for the wrapper; we want graceful degradation.
set +e +u +o pipefail

user_root="${NYANN_USER_ROOT:-${HOME}/.claude/nyann}"
target="$PWD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2:-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    *) shift ;;
  esac
done

prefs="$user_root/preferences.json"
[[ -f "$prefs" ]] || exit 0

# Opt-out — preferences.session_triage = false means do nothing.
# Use `if .session_triage == false then "false" else "true" end` rather
# than `// true` because jq's `//` treats literal false as null-equivalent
# and would always fall back to "true".
triage=$(jq -r 'if .session_triage == false then "false" else "true" end' "$prefs" 2>/dev/null)
[[ "$triage" == "false" ]] && exit 0

# Must be in a git repo.
( cd "$target" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) || exit 0

# Run with a 2s hard cap. GNU/BSD timeout is widely available; if missing,
# we fall back to a foreground call (still bounded by jq/git fast paths,
# but no hard cap).
cmd=(bash "${_script_dir}/session-check.sh" --user-root "$user_root" --flow=session-start)

if command -v timeout >/dev/null 2>&1; then
  ( cd "$target" && timeout 2s "${cmd[@]}" 2>/dev/null )
elif command -v gtimeout >/dev/null 2>&1; then
  ( cd "$target" && gtimeout 2s "${cmd[@]}" 2>/dev/null )
else
  ( cd "$target" && "${cmd[@]}" 2>/dev/null )
fi

# Always exit 0 — the hook contract says we never block.
exit 0
