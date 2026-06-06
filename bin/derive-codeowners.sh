#!/usr/bin/env bash
# derive-codeowners.sh — suggest CODEOWNERS mappings from git history.
#
# Usage:
#   derive-codeowners.sh --target <repo>
#                        [--min-commits <n>]     # default: 5
#                        [--max-entries <n>]      # default: 20
#
# Analyzes git history per top-level directory, ranks authors by commit
# count, and emits suggested ownership mappings. Bot accounts
# (dependabot, renovate, github-actions) are excluded.
#
# Authors are ranked by email (`%aE`), not display name: a CODEOWNERS
# owner must be an `@handle`, `@org/team`, or an email address — a bare
# display name ("Alice Wonderland") is rejected by GitHub and the rule
# is inert. From the top author's email we derive:
#   - a GitHub `@handle` when the email is a github.com noreply
#     (`12345+alice@users.noreply.github.com` → `@alice`), else
#   - the raw email when it looks like a real address, else
#   - no active owner — only a name suggestion for manual assignment.
#
# Output (JSON on stdout):
#   [ { "path": "/src/", "suggested_owner": "@alice",
#       "suggested_name": "Alice Wonderland",
#       "commit_count": 42, "confidence": 0.85 }, ... ]
#
# `suggested_owner` is a CODEOWNERS-valid owner or "" when none could be
# derived; `suggested_name` is always the display name (for a
# `# suggested:` comment when no valid owner exists).
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
    -h|--help)      sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

  # Rank authors by email (`%aE`), tab-joined with display name so we can
  # both derive a CODEOWNERS owner from the email and keep the name for a
  # suggestion comment. `grep -v` exits 1 when a dir's history is
  # entirely bots (no lines survive the filter); under `set -euo
  # pipefail` that would abort the whole script and lose every other
  # dir's data, so `|| true` neutralizes it — an all-bot dir yields an
  # empty top_author and is skipped below.
  # Tab separator between email and name. A literal tab inside a glob
  # confuses the static test-expression parser, so use a named variable.
  tab=$'\t'
  top_author=$( { git -C "$target" log --format="%aE${tab}%aN" -- "$dir" 2>/dev/null \
    | grep -v "$bot_pattern" || true; } \
    | sort | uniq -c | sort -rn | head -1)

  [[ -z "$top_author" ]] && continue

  count=$(printf '%s\n' "$top_author" | awk '{print $1}')
  # Strip the leading "<count> " from uniq -c, leaving "email<TAB>name".
  author_line=$(printf '%s' "$top_author" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
  author_email=${author_line%%"${tab}"*}
  if [[ "$author_line" == *"${tab}"* ]]; then
    author_name=${author_line#*"${tab}"}
  else
    author_name=""
  fi

  if (( count < min_commits )); then
    continue
  fi

  # Derive a CODEOWNERS-valid owner from the email. A bare display name is
  # never emitted as an active owner — GitHub rejects it and the rule is
  # inert. suggested_owner is left empty when nothing valid can be derived;
  # the name is still surfaced via suggested_name for a manual-assignment
  # comment in gen-codeowners.sh.
  suggested_owner=""
  if [[ "$author_email" =~ ^[0-9]+\+([A-Za-z0-9](-?[A-Za-z0-9])*)@users\.noreply\.github\.com$ ]]; then
    # GitHub noreply email (12345+alice@users.noreply.github.com) → @alice.
    suggested_owner="@${BASH_REMATCH[1]}"
  elif [[ "$author_email" =~ ^([A-Za-z0-9](-?[A-Za-z0-9])*)@users\.noreply\.github\.com$ ]]; then
    # Legacy noreply form without the numeric id prefix.
    suggested_owner="@${BASH_REMATCH[1]}"
  elif [[ "$author_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+$ ]]; then
    # Real-looking address → valid CODEOWNERS owner as-is.
    suggested_owner="$author_email"
  fi

  total_commits=$(git -C "$target" log --format='%H' -- "$dir" 2>/dev/null | wc -l | tr -d ' ')
  if (( total_commits > 0 )); then
    confidence=$(awk -v c="$count" -v t="$total_commits" 'BEGIN { printf "%.2f", c/t }')
  else
    confidence="0.00"
  fi

  results_json=$(jq \
    --arg path "/$dir/" \
    --arg owner "$suggested_owner" \
    --arg name "$author_name" \
    --argjson count "$count" \
    --argjson conf "$confidence" \
    '. + [{path:$path, suggested_owner:$owner, suggested_name:$name, commit_count:$count, confidence:$conf}]' \
    <<<"$results_json")
done < <(git -C "$target" ls-tree --name-only HEAD 2>/dev/null | head -50)

jq --argjson max "$max_entries" '
  sort_by(-.commit_count) | .[0:$max]
' <<<"$results_json"
