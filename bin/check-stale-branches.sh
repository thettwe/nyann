#!/usr/bin/env bash
# check-stale-branches.sh — categorise local branches by hygiene state.
#
# Usage:
#   check-stale-branches.sh --target <repo> [--base <branch>] [--days <n>]
#
# Reads local branches via `git for-each-ref refs/heads/`, then for each
# branch (excluding the current branch and the base) classifies into:
#
#   * merged_into_base[] — branch tip is reachable from base. Safe to
#     delete; the work is already integrated.
#   * stale_unmerged[]   — branch's last commit is older than --days
#     AND the tip is NOT reachable from base. Likely abandoned.
#
# Output: StaleBranchesReport JSON (see
# schemas/stale-branches-report.schema.json) on stdout.
#
# Doctor consumes this; bin/cleanup-branches.sh consumes the
# merged_into_base list to drive deletions.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
base_branch=""
days_threshold=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2:-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --base)     base_branch="${2:-}"; shift 2 ;;
    --base=*)   base_branch="${1#--base=}"; shift ;;
    --days)     days_threshold="${2:-90}"; shift 2 ;;
    --days=*)   days_threshold="${1#--days=}"; shift ;;
    -h|--help)  sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" && -d "$target/.git" ]] || nyann::die "$target is not a git repo"
[[ "$days_threshold" =~ ^[0-9]+$ ]] || nyann::die "--days must be a positive integer"
[[ "$days_threshold" -ge 1 ]] || nyann::die "--days must be >= 1"

# Resolve base branch: explicit > origin/HEAD > main > master.
if [[ -z "$base_branch" ]]; then
  if origin_head=$(git -C "$target" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    base_branch="${origin_head#origin/}"
  elif git -C "$target" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    base_branch="main"
  elif git -C "$target" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    base_branch="master"
  fi
fi

current_branch=$(git -C "$target" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")

# Soft-skip when base doesn't exist locally — empty arrays + skipped=true.
if [[ -z "$base_branch" ]] || ! git -C "$target" show-ref --verify --quiet "refs/heads/${base_branch}" 2>/dev/null; then
  jq -n --arg target "$target" --arg base "${base_branch:-}" --arg cur "$current_branch" \
    --argjson days "$days_threshold" --arg reason "base branch not found locally" '{
      target: $target,
      base_branch: $base,
      current_branch: $cur,
      days_threshold: $days,
      merged_into_base: [],
      stale_unmerged: [],
      summary: { merged_count: 0, stale_count: 0, skipped: true, skip_reason: $reason }
    }'
  exit 0
fi

base_sha=$(git -C "$target" rev-parse "refs/heads/${base_branch}")
now_ts=$(date +%s)
threshold_secs=$(( days_threshold * 86400 ))

merged_json='[]'
stale_json='[]'

while IFS=$'\t' read -r name iso committer_ts short_sha; do
  [[ -z "$name" ]] && continue
  # Skip the base branch itself and the current branch.
  [[ "$name" == "$base_branch" ]] && continue
  [[ "$name" == "$current_branch" ]] && continue

  branch_sha=$(git -C "$target" rev-parse "refs/heads/${name}")

  # Reachability: is branch_sha an ancestor of base_sha?
  # `git merge-base --is-ancestor` exits 0 when ancestor, 1 otherwise.
  if git -C "$target" merge-base --is-ancestor "$branch_sha" "$base_sha" 2>/dev/null; then
    merged_json=$(jq --arg n "$name" --arg ts "$iso" --arg sha "$short_sha" \
      '. + [{name:$n, last_commit_at:$ts, last_commit_sha:$sha}]' <<<"$merged_json")
    continue
  fi

  # Not merged. Check age.
  age_secs=$(( now_ts - committer_ts ))
  if (( age_secs > threshold_secs )); then
    days_old=$(( age_secs / 86400 ))
    stale_json=$(jq --arg n "$name" --arg ts "$iso" --arg sha "$short_sha" --argjson d "$days_old" \
      '. + [{name:$n, last_commit_at:$ts, last_commit_sha:$sha, days_old:$d}]' <<<"$stale_json")
  fi
done < <(git -C "$target" for-each-ref \
  --format='%(refname:short)%09%(committerdate:iso-strict)%09%(committerdate:unix)%09%(objectname:short)' \
  refs/heads/)

merged_count=$(jq 'length' <<<"$merged_json")
stale_count=$(jq 'length' <<<"$stale_json")

jq -n \
  --arg target "$target" \
  --arg base "$base_branch" \
  --arg cur "$current_branch" \
  --argjson days "$days_threshold" \
  --argjson merged "$merged_json" \
  --argjson stale "$stale_json" \
  --argjson mc "$merged_count" \
  --argjson sc "$stale_count" \
  '{
    target: $target,
    base_branch: $base,
    current_branch: $cur,
    days_threshold: $days,
    merged_into_base: $merged,
    stale_unmerged: $stale,
    summary: { merged_count: $mc, stale_count: $sc, skipped: false }
  }'
