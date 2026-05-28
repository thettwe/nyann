#!/usr/bin/env bash
# pr-risk-score.sh — compute a risk score for the current branch's changes.
#
# Usage:
#   pr-risk-score.sh --target <repo> [--base <branch>]
#                    [--profile <path>] [--health-file <path>]
#
# Scoring: churn (40%) + test gap (35%) + health delta (25%)
#   Each signal → 0–100 sub-score → weighted sum → final 0–100 score.
#
# Output (JSON on stdout):
#   { "score": N, "level": "low"|"medium"|"high"|"critical",
#     "breakdown": { "churn": {...}, "test_gap": {...}, "health_delta": {...} },
#     "recommendations": [...] }

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
base="main"
# shellcheck disable=SC2034
profile_path=""
health_file=""

# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --base)         base="${2:-}"; shift 2 ;;
    --base=*)       base="${1#--base=}"; shift ;;
    --profile)      profile_path="${2:-}"; shift 2 ;;
    --profile=*)    profile_path="${1#--profile=}"; shift ;;
    --health-file)  health_file="${2:-}"; shift 2 ;;
    --health-file=*) health_file="${1#--health-file=}"; shift ;;
    -h|--help)      sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "pr-risk-score: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "pr-risk-score: --target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "pr-risk-score: $target is not a git repo"

recommendations='[]'
_add_rec() {
  recommendations=$(jq --arg r "$1" '. + [$r]' <<<"$recommendations")
}

# --- churn score (40%) --------------------------------------------------------
# lines changed × files changed × hotspot factor

# shellcheck disable=SC2034
diff_stat=$(git -C "$target" diff --stat "${base}...HEAD" 2>/dev/null || true)
files_changed=$(git -C "$target" diff --name-only "${base}...HEAD" 2>/dev/null | wc -l | tr -d ' ')
lines_changed=$(git -C "$target" diff --shortstat "${base}...HEAD" 2>/dev/null | \
  awk '{for(i=1;i<=NF;i++) if($i ~ /insertion|deletion/) total+=$(i-1)} END{print total+0}')

hotspot_files='[]'
if (( files_changed > 0 )); then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ "$file" == *.md || "$file" == *.lock || "$file" == *.generated.* ]] && continue
    edits_90d=$(git -C "$target" log --since="90 days ago" --format='%H' -- "$file" 2>/dev/null | wc -l | tr -d ' ')
    if (( edits_90d > 5 )); then
      hotspot_files=$(jq --arg f "$file" '. + [$f]' <<<"$hotspot_files")
    fi
  done < <(git -C "$target" diff --name-only "${base}...HEAD" 2>/dev/null | head -50)
fi

hotspot_count=$(jq 'length' <<<"$hotspot_files")
churn_raw=$(awk -v f="$files_changed" -v l="$lines_changed" -v h="$hotspot_count" \
  'BEGIN { s = (l * (1 + h * 0.2)) / 50; if (s > 100) s = 100; printf "%d", s }')

# --- test gap score (35%) ----------------------------------------------------
# For each changed source file, check if a corresponding test also changed.

source_changes=0
test_changes=0
untested_changes='[]'

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ "$file" == *.md || "$file" == *.lock ]] && continue

  is_test=false
  case "$file" in
    tests/*|test/*|*_test.*|*.test.*|*.spec.*|*Test.*|*_spec.*) is_test=true ;;
  esac

  if $is_test; then
    ((test_changes++)) || true
    continue
  fi

  ((source_changes++)) || true

  test_found=false
  basename_no_ext="${file##*/}"
  basename_no_ext="${basename_no_ext%.*}"

  test_patterns=(
    "tests/bats/test-${basename_no_ext}.bats"
    "test/${basename_no_ext}.test.ts"
    "tests/${basename_no_ext}.test.ts"
    "tests/${basename_no_ext}.spec.ts"
    "tests/test_${basename_no_ext}.py"
    "__tests__/${basename_no_ext}.test.ts"
    "__tests__/${basename_no_ext}.test.tsx"
  )

  for pattern in "${test_patterns[@]}"; do
    if git -C "$target" diff --name-only "${base}...HEAD" 2>/dev/null | grep -Fq "$pattern"; then
      test_found=true
      break
    fi
  done

  if ! $test_found; then
    untested_changes=$(jq --arg f "$file" '. + [$f]' <<<"$untested_changes")
  fi
done < <(git -C "$target" diff --name-only "${base}...HEAD" 2>/dev/null)

untested_count=$(jq 'length' <<<"$untested_changes")
if (( source_changes > 0 )); then
  test_gap_raw=$(awk -v u="$untested_count" -v s="$source_changes" \
    'BEGIN { s = (u / s) * 100; if (s > 100) s = 100; printf "%d", s }')
else
  test_gap_raw=0
fi

# --- health delta score (25%) ------------------------------------------------

health_current=0
health_previous=0
health_delta=0

if [[ -z "$health_file" ]]; then
  health_file="$target/memory/health.json"
fi

if [[ -f "$health_file" ]]; then
  health_current=$(jq -r '.scores[-1].score // 0' "$health_file" 2>/dev/null || echo 0)
  health_previous=$(jq -r '.scores[-2].score // 0' "$health_file" 2>/dev/null || echo 0)
  health_delta=$((health_current - health_previous))
fi

if (( health_delta >= 0 )); then
  health_raw=$(awk -v d="$health_delta" 'BEGIN { s = 30 - d; if (s < 0) s = 0; printf "%d", s }')
else
  abs_delta=$(( -health_delta ))
  health_raw=$(awk -v d="$abs_delta" 'BEGIN { s = 50 + d * 5; if (s > 100) s = 100; printf "%d", s }')
fi

# --- weighted sum -------------------------------------------------------------

score=$(awk -v c="$churn_raw" -v t="$test_gap_raw" -v h="$health_raw" \
  'BEGIN { s = c * 0.4 + t * 0.35 + h * 0.25; printf "%d", s }')

if (( score <= 30 )); then
  level="low"
elif (( score <= 60 )); then
  level="medium"
elif (( score <= 80 )); then
  level="high"
else
  level="critical"
fi

# Recommendations
if (( untested_count > 0 )); then
  top_untested=$(jq -r '.[0]' <<<"$untested_changes")
  _add_rec "Consider adding test coverage for $top_untested"
fi
if (( health_delta < -5 )); then
  _add_rec "Health score dropped ${health_delta} points — run nyann:doctor before merging"
fi
if (( hotspot_count > 3 )); then
  _add_rec "This PR touches $hotspot_count hotspot files (>5 edits in 90 days) — consider splitting"
fi

jq -n \
  --argjson score "$score" \
  --arg level "$level" \
  --argjson churn_score "$churn_raw" \
  --argjson files_changed "$files_changed" \
  --argjson lines_changed "$lines_changed" \
  --argjson hotspot_files "$hotspot_files" \
  --argjson test_gap_score "$test_gap_raw" \
  --argjson untested "$untested_changes" \
  --argjson test_changes "$test_changes" \
  --argjson source_changes "$source_changes" \
  --argjson health_score "$health_raw" \
  --argjson health_current "$health_current" \
  --argjson health_previous "$health_previous" \
  --argjson health_delta "$health_delta" \
  --argjson recs "$recommendations" \
  '{
    score: $score,
    level: $level,
    breakdown: {
      churn: { score: $churn_score, weight: 0.4, files_changed: $files_changed, lines_changed: $lines_changed, hotspot_files: $hotspot_files },
      test_gap: { score: $test_gap_score, weight: 0.35, untested_changes: $untested, test_changes: $test_changes, source_changes: $source_changes },
      health_delta: { score: $health_score, weight: 0.25, current: $health_current, previous: $health_previous, delta: $health_delta }
    },
    recommendations: $recs
  }'
