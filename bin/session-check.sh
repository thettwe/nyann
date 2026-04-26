#!/usr/bin/env bash
# session-check.sh — lightweight drift check for session-start monitor.
#
# Usage: session-check.sh [--user-root <dir>]
#
# Resolves the active profile from preferences.json, runs doctor --json
# against the current directory, and emits a single notification line to
# stdout when drift is found. Exits silently (no output, rc 0) when:
#   - nyann setup has not been run yet
#   - current directory is not a git repo
#   - no drift detected
#   - any dependency is missing (jq, etc.)
#
# Designed to run as a background monitor — must never block, never
# prompt, never write to the filesystem.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source _lib.sh for helpers but trap any failure to exit cleanly.
# Monitor scripts must never crash noisily.
if ! source "${_script_dir}/_lib.sh" 2>/dev/null; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    *) shift ;;
  esac
done

prefs="$user_root/preferences.json"
[[ -f "$prefs" ]] || exit 0

# Not a git repo — nothing to check.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Resolve profile: preferences → CLAUDE.md markers → "default".
profile=$(jq -r '.default_profile // "auto-detect"' "$prefs" 2>/dev/null)

if [[ "$profile" == "auto-detect" || -z "$profile" ]]; then
  if [[ -f "CLAUDE.md" ]]; then
    marker_profile=$(sed -n 's/.*Profile *| *\([a-z0-9][a-z0-9-]*\).*/\1/p' CLAUDE.md 2>/dev/null | head -1)
    [[ -n "$marker_profile" ]] && profile="$marker_profile"
  fi
fi

if [[ "$profile" == "auto-detect" || -z "$profile" ]]; then
  profile="default"
fi

# Compute drift directly. Previously this called doctor.sh, which
# composed retrofit + compute-drift + persist-health-score — overkill
# for a session-start ping that only needs the summary counters, and
# an architectural inversion (a monitor-tier subsystem invoking an
# orchestrator). Calling compute-drift directly keeps session-check
# in the subsystem layer and skips the persistence side-effect doctor
# used to perform.
profile_tmp=$(mktemp -t nyann-session-profile.XXXXXX 2>/dev/null) || exit 0
trap 'rm -f "$profile_tmp"' EXIT
"${_script_dir}/load-profile.sh" "$profile" >"$profile_tmp" 2>/dev/null || exit 0
report=$("${_script_dir}/compute-drift.sh" --target "." --profile "$profile_tmp" 2>/dev/null) || exit 0
[[ -n "$report" ]] || exit 0

# Parse summary counters.
n_missing=$(jq -r '.summary.missing // 0' <<<"$report" 2>/dev/null) || exit 0
n_misconf=$(jq -r '.summary.misconfigured // 0' <<<"$report" 2>/dev/null) || exit 0
n_broken=$(jq -r '.summary.broken_links // 0' <<<"$report" 2>/dev/null) || exit 0
claude_status=$(jq -r '.summary.claude_md_status // "ok"' <<<"$report" 2>/dev/null) || exit 0

# Also probe local branch hygiene. The merged-branch count tends to
# pile up between releases and gets forgotten — surfacing it on
# session-start as soon as the threshold is crossed turns
# /nyann:cleanup-branches into a routine instead of a once-a-quarter
# bookkeeping chore. Threshold is env-tunable so users on
# release-heavy repos can dial it up without losing the nudge.
merged_threshold="${NYANN_MERGED_BRANCH_THRESHOLD:-3}"
[[ "$merged_threshold" =~ ^[0-9]+$ ]] || merged_threshold=3
n_merged=0
stale_report=$("${_script_dir}/check-stale-branches.sh" --target "." 2>/dev/null) || stale_report=""
if [[ -n "$stale_report" ]]; then
  parsed=$(jq -r '.summary.merged_count // 0' <<<"$stale_report" 2>/dev/null) && n_merged="$parsed"
fi

# Compute drift activation; merged-branch count gates its own nudge.
drift_total=$((n_missing + n_misconf + n_broken))
[[ "$claude_status" == "error" ]] && drift_total=$((drift_total + 1))
need_cleanup_nudge=0
(( n_merged >= merged_threshold )) && need_cleanup_nudge=1

# Nothing to surface → exit silently.
(( drift_total == 0 && need_cleanup_nudge == 0 )) && exit 0

# Health suffix (shared between drift line and cleanup-only line).
health_suffix=""
if [[ -f "memory/health.json" ]]; then
  h_score=$(jq -r '.scores[-1].score // ""' "memory/health.json" 2>/dev/null)
  h_dir=$(jq -r '.trend.direction // "stable"' "memory/health.json" 2>/dev/null)
  if [[ -n "$h_score" ]]; then
    case "$h_dir" in
      up)     health_suffix=" Health: ${h_score}/100 ↑" ;;
      down)   health_suffix=" Health: ${h_score}/100 ↓" ;;
      *)      health_suffix=" Health: ${h_score}/100 →" ;;
    esac
  fi
fi

if (( drift_total > 0 )); then
  # Drift line — when merged branches are also over threshold, fold
  # the cleanup CTA into the same notification rather than
  # double-pinging the user.
  parts=()
  (( n_missing > 0 )) && parts+=("${n_missing} missing")
  (( n_misconf > 0 )) && parts+=("${n_misconf} misconfigured")
  (( n_broken > 0 )) && parts+=("${n_broken} broken links")
  [[ "$claude_status" == "error" ]] && parts+=("CLAUDE.md over budget")
  msg=$(IFS=", "; echo "${parts[*]}")

  if (( need_cleanup_nudge == 1 )); then
    echo "[nyann] drift detected vs '${profile}' profile: ${msg}.${health_suffix} Run /nyann:retrofit to fix; /nyann:cleanup-branches to prune ${n_merged} merged branches."
  else
    echo "[nyann] drift detected vs '${profile}' profile: ${msg}.${health_suffix} Run /nyann:retrofit to fix."
  fi
else
  # Cleanup-only line — no profile drift, but enough merged branches
  # piled up that it's worth a top-level ping.
  echo "[nyann] hygiene: ${n_merged} merged branches sitting locally.${health_suffix} Run /nyann:cleanup-branches to prune."
fi
