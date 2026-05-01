#!/usr/bin/env bash
# health-trend.sh — read persisted health scores and emit a trend report.
#
# Usage:
#   health-trend.sh --target <repo> [--last <n>] [--format human|json]
#
# Reads memory/health.json (written by persist-health-score.sh) and produces
# a trend report: score trajectory, per-category deltas, best/worst windows.
#
# Exit codes:
#   0 — report generated
#   1 — no health history found or bad arguments

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
last=10
fmt="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --last)         last="${2:-10}"; shift 2 ;;
    --last=*)       last="${1#--last=}"; shift ;;
    --format)       fmt="${2:-json}"; shift 2 ;;
    --format=*)     fmt="${1#--format=}"; shift ;;
    -h|--help)      sed -n '3,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"

case "$fmt" in
  human|json) ;;
  *) nyann::die "--format must be human|json" ;;
esac

[[ "$last" =~ ^[0-9]+$ && "$last" -ge 1 ]] \
  || nyann::die "--last must be a positive integer"

health_file="$target/memory/health.json"
if [[ ! -f "$health_file" ]]; then
  nyann::die "no health history at $health_file — run doctor + persist first"
fi

health_json=$(cat "$health_file")
total_entries=$(jq '.scores | length' <<<"$health_json")
if (( total_entries == 0 )); then
  nyann::die "health.json has no score entries"
fi

# Slice to --last entries.
scores_json=$(jq --argjson n "$last" '.scores | .[-$n:]' <<<"$health_json")
window_size=$(jq 'length' <<<"$scores_json")

# Current, min, max, average.
current=$(jq '.[-1].score' <<<"$scores_json")
min_score=$(jq '[.[].score] | min' <<<"$scores_json")
max_score=$(jq '[.[].score] | max' <<<"$scores_json")
avg_score=$(jq '[.[].score] | add / length | floor' <<<"$scores_json")

# Compute direction from the windowed scores (not the persisted global trend,
# which reflects the full history and may disagree with the requested window).
read -r direction delta < <(jq -r '
  if length < 2 then "stable 0"
  else
    (.[-1].score) as $latest |
    (.[:-1] | .[-5:] | map(.score) | add / length | floor) as $avg |
    ($latest - $avg) as $d |
    (if $d > 2 then "up" elif $d < -2 then "down" else "stable" end) as $dir |
    "\($dir) \($d)"
  end
' <<<"$scores_json")

# Per-category trend: compare latest breakdown vs earliest in window.
category_deltas=$(jq '
  (.[0].breakdown // {}) as $first |
  (.[-1].breakdown // {}) as $latest |
  ($first | keys) + ($latest | keys) | unique |
  map(. as $k |
    {category: $k,
     first: ($first[$k] // 0),
     latest: ($latest[$k] // 0),
     delta: (($latest[$k] // 0) - ($first[$k] // 0))}) |
  sort_by(.delta)
' <<<"$scores_json")

# Sparkline: map scores to block characters.
sparkline=$(jq -r '
  [.[].score] |
  (min) as $lo | (max) as $hi |
  (if $hi == $lo then 1 else ($hi - $lo) end) as $range |
  map(
    ((. - $lo) / $range * 7 | floor) as $idx |
    ["▁","▂","▃","▄","▅","▆","▇","█"][$idx]
  ) | join("")
' <<<"$scores_json")

# Score timeline for human output.
timeline_json=$(jq '[.[] | {timestamp: .timestamp, score: .score}]' <<<"$scores_json")

if [[ "$fmt" == "json" ]]; then
  jq -n \
    --argjson current "$current" \
    --argjson min_score "$min_score" \
    --argjson max_score "$max_score" \
    --argjson avg_score "$avg_score" \
    --arg direction "$direction" \
    --argjson delta "$delta" \
    --argjson window_size "$window_size" \
    --argjson total_entries "$total_entries" \
    --arg sparkline "$sparkline" \
    --argjson category_deltas "$category_deltas" \
    --argjson timeline "$timeline_json" \
    '{
      current: $current,
      min: $min_score,
      max: $max_score,
      avg: $avg_score,
      direction: $direction,
      delta: $delta,
      window_size: $window_size,
      total_entries: $total_entries,
      sparkline: $sparkline,
      category_deltas: $category_deltas,
      timeline: $timeline
    }'
else
  printf 'Health Score Trend (%d of %d entries)\n' "$window_size" "$total_entries"
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf 'Current: %d/100  |  Avg: %d  |  Min: %d  |  Max: %d\n' \
    "$current" "$avg_score" "$min_score" "$max_score"
  printf 'Direction: %s (delta: %+d)\n\n' "$direction" "$delta"
  printf 'Sparkline: %s\n\n' "$sparkline"

  printf 'Timeline:\n'
  jq -r '.[] | "  \(.timestamp)  \(.score)/100"' <<<"$timeline_json"

  improving=$(jq '[.[] | select(.delta < 0)] | length' <<<"$category_deltas")
  worsening=$(jq '[.[] | select(.delta > 0)] | length' <<<"$category_deltas")
  if (( improving > 0 || worsening > 0 )); then
    printf '\nCategory changes (first → latest in window):\n'
    # Deductions are negative, so delta < 0 = worse, delta > 0 = better... wait, no.
    # Breakdown values are negative deductions. A delta of -3 means 3 more points deducted = worse.
    # A delta of +3 means 3 fewer points deducted = better.
    jq -r '.[] | select(.delta != 0) |
      (if .delta > 0 then "  ↑ improved" else "  ↓ worsened" end) +
      "  " + .category + " (" + (if .delta > 0 then "+" else "" end) + (.delta | tostring) + ")"
    ' <<<"$category_deltas"
  fi
fi
