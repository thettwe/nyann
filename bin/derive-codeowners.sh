#!/usr/bin/env bash
# derive-codeowners.sh — suggest CODEOWNERS mappings from git history.
#
# Usage:
#   derive-codeowners.sh --target <repo>
#                        [--min-commits <n>]     # default: 5
#                        [--max-entries <n>]      # default: 20
#
# Analyzes `git log --format='%aN'` per top-level directory, ranks
# authors by commit count, and emits suggested ownership mappings.
# Bot accounts (dependabot, renovate, github-actions) are excluded.
#
# Output (JSON on stdout):
#   [ { "path": "/src/", "suggested_owner": "@alice",
#       "commit_count": 42, "confidence": 0.85 }, ... ]
#
# This script does NOT write CODEOWNERS. Its output feeds into
# gen-codeowners.sh --derived-owners.
#
# Exit codes:
#   0 — suggestions generated (may be empty array)
#   2 — bad arguments

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq
nyann::require_cmd git

target="$PWD"
min_commits=5
max_entries=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --min-commits)  min_commits="${2:-}"; shift 2 ;;
    --min-commits=*) min_commits="${1#--min-commits=}"; shift ;;
    --max-entries)  max_entries="${2:-}"; shift 2 ;;
    --max-entries=*) max_entries="${1#--max-entries=}"; shift ;;
    -h|--help)      sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "derive-codeowners: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "derive-codeowners: --target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "derive-codeowners: $target is not a git repo"

bot_pattern='dependabot\[bot\]\|renovate\[bot\]\|github-actions\[bot\]\|semantic-release-bot\|greenkeeper\[bot\]'

results_json='[]'

while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  [[ -d "$target/$dir" ]] || continue

  top_author=$(git -C "$target" log --format='%aN' -- "$dir" 2>/dev/null \
    | grep -v "$bot_pattern" \
    | sort | uniq -c | sort -rn | head -1)

  [[ -z "$top_author" ]] && continue

  count=$(echo "$top_author" | awk '{print $1}')
  author=$(echo "$top_author" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')

  if (( count < min_commits )); then
    continue
  fi

  total_commits=$(git -C "$target" log --format='%H' -- "$dir" 2>/dev/null | wc -l | tr -d ' ')
  if (( total_commits > 0 )); then
    confidence=$(awk -v c="$count" -v t="$total_commits" 'BEGIN { printf "%.2f", c/t }')
  else
    confidence="0.00"
  fi

  results_json=$(jq \
    --arg path "/$dir/" \
    --arg owner "$author" \
    --argjson count "$count" \
    --argjson conf "$confidence" \
    '. + [{path:$path, suggested_owner:$owner, commit_count:$count, confidence:$conf}]' \
    <<<"$results_json")
done < <(git -C "$target" ls-tree --name-only HEAD 2>/dev/null | head -50)

jq --argjson max "$max_entries" '
  sort_by(-.commit_count) | .[0:$max]
' <<<"$results_json"
