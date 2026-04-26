#!/usr/bin/env bash
# persist-health-score.sh — append a health score to memory/health.json.
#
# Usage:
#   persist-health-score.sh --target <repo> --score <path>
#                           [--profile <name>]
#
# Creates memory/health.json if it doesn't exist. Keeps last 90 entries
# (rolling window). Computes trend from recent scores.
# Idempotent: same timestamp + score doesn't create duplicate entries.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
score_path=""
profile_name="unknown"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --score)        score_path="${2:-}"; shift 2 ;;
    --score=*)      score_path="${1#--score=}"; shift ;;
    --profile)      profile_name="${2:-unknown}"; shift 2 ;;
    --profile=*)    profile_name="${1#--profile=}"; shift ;;
    -h|--help)      sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$score_path" && -f "$score_path" ]] || nyann::die "--score <path> is required and must exist"
target="$(cd "$target" && pwd)"

score_json=$(cat "$score_path")
score_val=$(jq -r '.score' <<<"$score_json")
breakdown=$(jq -c '.breakdown' <<<"$score_json")

health_file="$target/memory/health.json"
[[ -L "$health_file" ]] && nyann::die "refusing to write health score via symlink: $health_file"
mkdir -p "$(dirname "$health_file")"

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

new_entry=$(jq -n \
  --arg ts "$timestamp" \
  --argjson score "$score_val" \
  --arg profile "$profile_name" \
  --argjson breakdown "$breakdown" \
  '{ timestamp: $ts, score: $score, profile: $profile, breakdown: $breakdown }')

# Initialize if doesn't exist
if [[ ! -f "$health_file" ]]; then
  jq -n --argjson entry "$new_entry" \
    '{ scores: [$entry], trend: { direction: "stable", delta: 0, window_days: 7 } }' \
    > "$health_file"
  nyann::log "created health.json with initial score: $score_val"
  printf '%s\n' "$(cat "$health_file")"
  exit 0
fi

existing=$(cat "$health_file")

# Dedup: skip if last entry has same score
last_score=$(jq -r '.scores[-1].score // -1' <<<"$existing")
last_ts=$(jq -r '.scores[-1].timestamp // ""' <<<"$existing")
if [[ "$last_score" == "$score_val" && "$last_ts" == "$timestamp" ]]; then
  nyann::log "duplicate entry (same timestamp + score) — skipping"
  printf '%s\n' "$existing"
  exit 0
fi

# Append and prune to 90 entries
updated=$(jq --argjson entry "$new_entry" '
  .scores += [$entry] |
  .scores = (.scores | .[-90:])
' <<<"$existing")

# Compute trend: compare latest to average of previous 5
updated=$(jq '
  .scores as $s |
  if ($s | length) < 2 then
    .trend = { direction: "stable", delta: 0, window_days: 7 }
  else
    ($s[-1].score) as $latest |
    ($s[:-1] | .[-5:] | map(.score) | add / length | floor) as $avg |
    ($latest - $avg) as $delta |
    (if $delta > 2 then "up"
     elif $delta < -2 then "down"
     else "stable" end) as $dir |
    .trend = { direction: $dir, delta: $delta, window_days: 7 }
  end
' <<<"$updated")

health_tmp=$(mktemp -t nyann-health.XXXXXX)
trap 'rm -f "$health_tmp"' EXIT
printf '%s\n' "$updated" > "$health_tmp"
mv "$health_tmp" "$health_file"

direction=$(jq -r '.trend.direction' <<<"$updated")
delta=$(jq -r '.trend.delta' <<<"$updated")
nyann::log "health score: $score_val/100 (${direction}, delta: ${delta})"
printf '%s\n' "$updated"
