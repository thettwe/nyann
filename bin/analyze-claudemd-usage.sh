#!/usr/bin/env bash
# analyze-claudemd-usage.sh — analyze CLAUDE.md usage patterns and recommend optimizations.
#
# Usage:
#   analyze-claudemd-usage.sh --target <repo> [--min-sessions <n>] [--force]
#
# Reads memory/claudemd-usage.json and current CLAUDE.md, computes per-section
# density (references / bytes), and outputs JSON recommendations.
# Minimum 10 sessions before making recommendations (--force to override).
#
# Output: JSON analysis object.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
min_sessions=10
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         target="${2:-}"; shift 2 ;;
    --target=*)       target="${1#--target=}"; shift ;;
    --min-sessions)   min_sessions="${2:-10}"; shift 2 ;;
    --min-sessions=*) min_sessions="${1#--min-sessions=}"; shift ;;
    --force)          force=true; shift ;;
    -h|--help)        sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ "$min_sessions" =~ ^[0-9]+$ ]] || nyann::die "--min-sessions must be a positive integer"
target="$(cd "$target" && pwd)"

usage_file="$target/memory/claudemd-usage.json"
claudemd="$target/CLAUDE.md"

[[ -f "$usage_file" ]] || nyann::die "no usage data found at $usage_file — enable tracking first"
[[ -f "$claudemd" ]] || nyann::die "no CLAUDE.md found at $claudemd"

usage_json=$(cat "$usage_file")
sessions=$(jq -r '.sessions // 0' <<<"$usage_json")

if [[ "$force" != "true" && "$sessions" -lt "$min_sessions" ]]; then
  jq -n --argjson sessions "$sessions" --argjson min "$min_sessions" '{
    total_sessions: $sessions,
    sufficient_data: false,
    minimum_sessions: $min,
    section_analysis: [],
    unused_docs: [],
    missing_commands: [],
    budget_used: 0,
    budget_remaining: 3072,
    recommendations: []
  }'
  exit 0
fi

# Extract nyann-managed sections from CLAUDE.md
# Sections are identified by markdown headers within the nyann block
marker_start="<!-- nyann:start -->"
marker_end="<!-- nyann:end -->"

nyann_block=""
if grep -qF "$marker_start" "$claudemd"; then
  nyann_block=$(sed -n "/${marker_start}/,/${marker_end}/p" "$claudemd")
fi

# Compute total CLAUDE.md size
total_bytes=$(wc -c < "$claudemd" | tr -d ' ')

# Build section analysis using jq
# Parse sections from the nyann block by splitting on ## headers
section_analysis='[]'
if [[ -n "$nyann_block" ]]; then
  current_section=""
  current_bytes=0

  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+(.*) ]]; then
      if [[ -n "$current_section" ]]; then
        refs=$(jq -r --arg s "$current_section" '.sections[$s].referenced // 0' <<<"$usage_json")
        density=0
        if [[ "$current_bytes" -gt 0 ]]; then
          density=$(awk -v refs="$refs" -v bytes="$current_bytes" 'BEGIN { printf "%.4f", refs / bytes }')
        fi
        verdict="keep"
        if (( $(awk -v d="$density" -v s="$sessions" 'BEGIN { print (d < 0.01 && s > 10) ? 1 : 0 }') )); then
          verdict="remove"
        elif (( $(awk -v d="$density" 'BEGIN { print (d < 0.05) ? 1 : 0 }') )); then
          verdict="compress"
        fi
        section_analysis=$(jq --arg sec "$current_section" --argjson bytes "$current_bytes" \
          --argjson refs "$refs" --arg density "$density" --arg verdict "$verdict" \
          '. + [{ section: $sec, bytes: $bytes, references: ($refs | tonumber), density: ($density | tonumber), verdict: $verdict }]' \
          <<<"$section_analysis")
      fi
      current_section="${BASH_REMATCH[1]}"
      current_bytes=${#line}
    elif [[ -n "$current_section" ]]; then
      current_bytes=$((current_bytes + ${#line} + 1))
    fi
  done <<<"$nyann_block"

  # Process last section
  if [[ -n "$current_section" ]]; then
    refs=$(jq -r --arg s "$current_section" '.sections[$s].referenced // 0' <<<"$usage_json")
    density=0
    if [[ "$current_bytes" -gt 0 ]]; then
      density=$(awk -v refs="$refs" -v bytes="$current_bytes" 'BEGIN { printf "%.4f", refs / bytes }')
    fi
    verdict="keep"
    if (( $(awk -v d="$density" -v s="$sessions" 'BEGIN { print (d < 0.01 && s > 10) ? 1 : 0 }') )); then
      verdict="remove"
    elif (( $(awk -v d="$density" 'BEGIN { print (d < 0.05) ? 1 : 0 }') )); then
      verdict="compress"
    fi
    section_analysis=$(jq --arg sec "$current_section" --argjson bytes "$current_bytes" \
      --argjson refs "$refs" --arg density "$density" --arg verdict "$verdict" \
      '. + [{ section: $sec, bytes: $bytes, references: ($refs | tonumber), density: ($density | tonumber), verdict: $verdict }]' \
      <<<"$section_analysis")
  fi
fi

# Find docs referenced in CLAUDE.md but never read
unused_docs='[]'
while IFS= read -r doc_link; do
  [[ -z "$doc_link" ]] && continue
  read_count=$(jq -r --arg d "$doc_link" '.docs_read[$d] // 0' <<<"$usage_json")
  if [[ "$read_count" -eq 0 ]]; then
    unused_docs=$(jq --arg d "$doc_link" '. + [$d]' <<<"$unused_docs")
  fi
done < <(grep -oE '\[.*\]\((docs/[^)]+|memory/[^)]+)\)' "$claudemd" 2>/dev/null | grep -oE '(docs|memory)/[^)]+' | sort -u || true)

# Find frequently-run commands not in CLAUDE.md
missing_commands='[]'
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  count=$(jq -r --arg c "$cmd" '.commands_run[$c]' <<<"$usage_json")
  [[ "$count" == "null" || -z "$count" ]] && continue
  if [[ "$count" -ge 3 ]] && ! grep -Fq "$cmd" "$claudemd" 2>/dev/null; then
    missing_commands=$(jq --arg c "$cmd" '. + [$c]' <<<"$missing_commands")
  fi
done < <(jq -r '.commands_run // {} | keys[]' <<<"$usage_json" 2>/dev/null || true)

# Build recommendations
recommendations='[]'

# Recommend compression for low-density sections
while IFS= read -r sec_json; do
  [[ -z "$sec_json" ]] && continue
  verdict=$(jq -r '.verdict' <<<"$sec_json")
  section=$(jq -r '.section' <<<"$sec_json")
  bytes=$(jq -r '.bytes' <<<"$sec_json")
  if [[ "$verdict" == "compress" ]]; then
    savings=$((bytes / 3))
    recommendations=$(jq --arg sec "$section" --arg reason "low reference density" --argjson savings "$savings" \
      '. + [{ action: "compress", section: $sec, reason: $reason, savings_bytes: $savings }]' \
      <<<"$recommendations")
  elif [[ "$verdict" == "remove" ]]; then
    recommendations=$(jq --arg sec "$section" --arg reason "never referenced" --argjson savings "$bytes" \
      '. + [{ action: "remove", section: $sec, reason: $reason, savings_bytes: $savings }]' \
      <<<"$recommendations")
  fi
done < <(jq -c '.[]' <<<"$section_analysis" 2>/dev/null || true)

# Recommend adding missing commands
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  recommendations=$(jq --arg cmd "$cmd" --arg reason "frequently run but not documented" \
    '. + [{ action: "add", content: $cmd, reason: $reason }]' \
    <<<"$recommendations")
done < <(jq -r '.[]' <<<"$missing_commands" 2>/dev/null || true)

budget=3072
budget_remaining=$((budget > total_bytes ? budget - total_bytes : 0))

jq -n \
  --argjson sessions "$sessions" \
  --argjson section_analysis "$section_analysis" \
  --argjson unused_docs "$unused_docs" \
  --argjson missing_commands "$missing_commands" \
  --argjson budget_used "$total_bytes" \
  --argjson budget_remaining "$budget_remaining" \
  --argjson recommendations "$recommendations" \
  '{
    total_sessions: $sessions,
    sufficient_data: true,
    section_analysis: $section_analysis,
    unused_docs: $unused_docs,
    missing_commands: $missing_commands,
    budget_used: $budget_used,
    budget_remaining: $budget_remaining,
    recommendations: $recommendations
  }'
