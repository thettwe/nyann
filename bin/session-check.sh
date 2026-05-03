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
"${_script_dir}/load-profile.sh" --user-root "$user_root" "$profile" >"$profile_tmp" 2>/dev/null || exit 0
report=$("${_script_dir}/compute-drift.sh" --target "." --profile "$profile_tmp" 2>/dev/null) || exit 0
[[ -n "$report" ]] || exit 0

# Parse summary counters.
n_missing=$(jq -r '.summary.missing // 0' <<<"$report" 2>/dev/null) || exit 0
n_misconf=$(jq -r '.summary.misconfigured // 0' <<<"$report" 2>/dev/null) || exit 0
n_broken=$(jq -r '.summary.broken_links // 0' <<<"$report" 2>/dev/null) || exit 0
claude_status=$(jq -r '.summary.claude_md_status // "ok"' <<<"$report" 2>/dev/null) || exit 0

# Also probe local branch hygiene. Cache the result keyed by HEAD SHA
# so repeated skill invocations in the same session (commit → pr → ship)
# don't re-run git for-each-ref + branch classification each time.
merged_threshold="${NYANN_MERGED_BRANCH_THRESHOLD:-3}"
[[ "$merged_threshold" =~ ^[0-9]+$ ]] || merged_threshold=3
n_merged=0

head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
refs_hash=$(git for-each-ref --format='%(refname)%(objectname)' refs/heads/ 2>/dev/null | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | cut -c1-12)
cache_dir="${TMPDIR:-/tmp}/nyann-session-cache"
_dir_hash=$(printf '%s' "$(pwd)" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | cut -c1-12)
cache_file="$cache_dir/stale-branches-${_dir_hash:-fallback}"
cache_ttl=60

stale_report=""
if [[ -n "$head_sha" && -f "$cache_file" ]]; then
  cached_sha=$(head -1 "$cache_file" 2>/dev/null || echo "")
  cached_refs=$(sed -n '2p' "$cache_file" 2>/dev/null || echo "")
  cached_ts=$(sed -n '3p' "$cache_file" 2>/dev/null || echo "0")
  now_ts=$(date +%s)
  if [[ "$cached_sha" == "$head_sha" && "$cached_refs" == "$refs_hash" ]] && (( now_ts - cached_ts < cache_ttl )); then
    stale_report=$(tail -n +4 "$cache_file" 2>/dev/null || echo "")
  fi
fi

if [[ -z "$stale_report" ]]; then
  stale_report=$("${_script_dir}/check-stale-branches.sh" --target "." 2>/dev/null) || stale_report=""
  if [[ -n "$head_sha" && -n "$stale_report" ]]; then
    mkdir -p "$cache_dir" 2>/dev/null || true
    { printf '%s\n%s\n%s\n%s\n' "$head_sha" "$refs_hash" "$(date +%s)" "$stale_report"; } > "$cache_file" 2>/dev/null || true
  fi
fi

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
