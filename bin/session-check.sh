#!/usr/bin/env bash
# session-check.sh — lightweight drift check for session-start monitor
# and inline drift checks at point-of-use (commit / release / pr / ship).
#
# Usage:
#   session-check.sh [--user-root <dir>] [--flow=<commit|release|pr|ship>]
#
# Resolves the active profile from preferences.json, runs doctor --json
# against the current directory, and emits a single notification line to
# stdout when drift is found. Exits silently (no output, rc 0) when:
#   - nyann setup has not been run yet
#   - current directory is not a git repo
#   - no drift detected
#   - any dependency is missing (jq, etc.)
#
# When --flow=<verb> is passed, the emitted message includes a
# flow-specific suffix so the calling skill (commit/release/pr/ship) can
# surface the output verbatim without per-skill boilerplate. This is the
# v1.6.0 drift-check dedup contract: skills pass --flow=<verb>, the
# script prints one self-contained line, the skill surfaces it as-is.
# Unknown flow values are rejected with a clear error.
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
flow=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    --flow)        flow="${2:-}"; shift 2 ;;
    --flow=*)      flow="${1#--flow=}"; shift ;;
    *) shift ;;
  esac
done

# Validate --flow when set. Per design: keep the canonical verbs
# matching the SKILL.md callers; reject anything else loudly so a typo
# in a skill (e.g. --flow=commits) surfaces immediately rather than
# silently degrading to no-suffix output.
# session-start is dedup'd via fingerprint cache rather than treated as a
# flow noun.
case "$flow" in
  ""|commit|release|pr|ship|session-start) ;;
  *)
    echo "[nyann] error: --flow value '${flow}' is not one of commit|release|pr|ship|session-start" >&2
    exit 2
    ;;
esac

# Map flow verb to the user-facing noun used in the suffix. Mostly
# identity, but pr → PR for casing. session-start has no suffix.
case "$flow" in
  commit)        flow_noun="commit" ;;
  release)       flow_noun="release" ;;
  pr)            flow_noun="PR" ;;
  ship)          flow_noun="ship" ;;
  session-start) flow_noun="" ;;
  *)             flow_noun="" ;;
esac

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
report=$("${_script_dir}/compute-drift.sh" --target "$PWD" --profile "$profile_tmp" 2>/dev/null) || exit 0
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
cache_ttl=60
# When either hash failed (no md5sum/md5/cksum on PATH, or git refs read
# failed), disable caching entirely. The previous fallback file name
# `stale-branches-fallback` was shared across every repo on the machine,
# so one repo's stale-branch JSON would surface for every other repo for
# 60 seconds — a silent cross-repo correctness leak.
if [[ -z "$_dir_hash" || -z "$refs_hash" ]]; then
  cache_ttl=0
  cache_file=""
else
  cache_file="$cache_dir/stale-branches-${_dir_hash}"
fi

stale_report=""
if [[ -n "$head_sha" && -n "$cache_file" && -f "$cache_file" ]]; then
  # Read all four sections in a single pass via awk so a concurrent
  # writer can't surface a partial cache between our reads. The 4th
  # section (the JSON payload) may itself contain newlines, so we keep
  # everything from line 4 onward.
  cache_payload=$(awk 'NR==1{a=$0; next} NR==2{b=$0; next} NR==3{c=$0; next} {if (d=="") d=$0; else d=d "\n" $0} END{printf "%s\n%s\n%s\n%s", a, b, c, d}' "$cache_file" 2>/dev/null || echo "")
  cached_sha=$(printf '%s\n' "$cache_payload" | sed -n '1p')
  cached_refs=$(printf '%s\n' "$cache_payload" | sed -n '2p')
  cached_ts=$(printf '%s\n' "$cache_payload" | sed -n '3p')
  [[ "$cached_ts" =~ ^[0-9]+$ ]] || cached_ts=0
  now_ts=$(date +%s)
  if [[ "$cached_sha" == "$head_sha" && "$cached_refs" == "$refs_hash" ]] && (( now_ts - cached_ts < cache_ttl )); then
    stale_report=$(printf '%s\n' "$cache_payload" | tail -n +4)
  fi
fi

if [[ -z "$stale_report" ]]; then
  stale_report=$("${_script_dir}/check-stale-branches.sh" --target "$PWD" 2>/dev/null) || stale_report=""
  # Atomic write: a concurrent reader (commit → pr → ship in quick
  # succession can spawn parallel session-checks) must never observe
  # a half-written cache. Write to a per-PID tmp file then mv into
  # place; mv is atomic on the same filesystem.
  if [[ -n "$head_sha" && -n "$stale_report" && -n "$cache_file" && "$cache_ttl" -gt 0 ]]; then
    mkdir -p "$cache_dir" 2>/dev/null || true
    cache_tmp="${cache_file}.tmp.$$"
    if { printf '%s\n%s\n%s\n%s\n' "$head_sha" "$refs_hash" "$(date +%s)" "$stale_report"; } > "$cache_tmp" 2>/dev/null; then
      mv "$cache_tmp" "$cache_file" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null
    else
      rm -f "$cache_tmp" 2>/dev/null || true
    fi
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

# Fingerprint dedup for session-start: suppress repeat output when the
# drift state hasn't changed since the last session-start check. Other
# flows (commit/pr/release/ship) bypass this — they need the warning
# every time because they're about to mutate.
if [[ "$flow" == "session-start" ]]; then
  fp_dir="${NYANN_USER_ROOT:-${HOME}/.claude/nyann}/cache"
  mkdir -p "$fp_dir" 2>/dev/null || true
  repo_hash=$(printf '%s' "$(pwd)" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | cut -c1-12)
  if [[ -n "$repo_hash" ]]; then
    fp_file="$fp_dir/$repo_hash.session-check"
    new_fp=$(printf '%s|%s|%s|%s|%s|%s\n' \
      "$n_missing" "$n_misconf" "$n_broken" "$claude_status" "$n_merged" "$profile" \
      | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) \
      | cut -c1-32)
    if [[ -f "$fp_file" ]]; then
      old_fp=$(head -c 64 "$fp_file" 2>/dev/null | tr -d '\r\n')
      if [[ "$old_fp" == "$new_fp" ]]; then
        # Same state as last session-start. Silent.
        exit 0
      fi
    fi
    # State changed (or first run). Update fingerprint atomically. The
    # write→rename pair uses explicit nested `if` blocks (rather than
    # `A && B || C`) so the cleanup branch is unambiguously the failure
    # path of the whole sequence.
    fp_tmp="${fp_file}.tmp.$$"
    if printf '%s\n' "$new_fp" > "$fp_tmp" 2>/dev/null; then
      if ! mv "$fp_tmp" "$fp_file" 2>/dev/null; then
        rm -f "$fp_tmp" 2>/dev/null
      fi
    else
      rm -f "$fp_tmp" 2>/dev/null
    fi
  fi
fi

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

# Flow-context suffix — appended only when --flow was passed by a
# skill caller. Communicates that the drift is informational and the
# in-flight skill flow is continuing.
flow_suffix=""
[[ -n "$flow_noun" ]] && flow_suffix=" (non-blocking — proceeding with the ${flow_noun} flow.)"

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
    echo "[nyann] drift detected vs '${profile}' profile: ${msg}.${health_suffix} Run /nyann:retrofit to fix; /nyann:cleanup-branches to prune ${n_merged} merged branches.${flow_suffix}"
  else
    echo "[nyann] drift detected vs '${profile}' profile: ${msg}.${health_suffix} Run /nyann:retrofit to fix.${flow_suffix}"
  fi
else
  # Cleanup-only line — no profile drift, but enough merged branches
  # piled up that it's worth a top-level ping.
  echo "[nyann] hygiene: ${n_merged} merged branches sitting locally.${health_suffix} Run /nyann:cleanup-branches to prune.${flow_suffix}"
fi
