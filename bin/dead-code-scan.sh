#!/usr/bin/env bash
# dead-code-scan.sh — scan the staged diff for unused imports / variables.
#
# Usage:
#   dead-code-scan.sh [--target <dir>] [--staged-only] [--include-medium]
#
# Default behavior: scan files appearing in `git diff --cached --name-only`
# under <target>, dispatch each file to its stack-specific rule under
# bin/dead-code-rules/<rule>.sh, aggregate findings into DeadCodeScanResult
# JSON on stdout.
#
# Only high-confidence findings are surfaced unless --include-medium is
# passed. Single-file heuristics can't see cross-file usage, so anything
# below "high" is suppressed by default to keep the false-positive rate
# tolerable for commit-time use.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
staged_only=true
include_medium=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --staged-only)   staged_only=true; shift ;;
    --no-staged-only) staged_only=false; shift ;;
    --include-medium) include_medium=true; shift ;;
    -h|--help)       sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"

cd "$target" || nyann::die "cd $target failed"

# Determine file list. Staged-only mode is the safe default — single-file
# heuristics are too noisy to apply to the whole tree.
if $staged_only; then
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -n --arg t "$target" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{target:$t, scanned_at:$ts, summary:{total:0, high_confidence:0, medium_confidence:0}, findings:[]}'
    exit 0
  fi
  files=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
else
  files=$(find . -type f -not -path './.git/*' 2>/dev/null)
fi

# Map extension → rule.
rule_for() {
  case "$1" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs) echo js ;;
    *.py)                              echo python ;;
    *.go)                              echo go ;;
    *.rs)                              echo rust ;;
    *) echo "" ;;
  esac
}

all_findings="[]"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$f" ]] || continue
  rule=$(rule_for "$f")
  [[ -z "$rule" ]] && continue
  rule_script="${_script_dir}/dead-code-rules/${rule}.sh"
  [[ -x "$rule_script" || -f "$rule_script" ]] || continue
  # Each rule emits NDJSON; collect lines.
  abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  lines=$(bash "$rule_script" "$abs" 2>/dev/null || true)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      # Rewrite the file path to be relative to target for cleaner output.
      rel="${abs#"${target}"/}"
      finding=$(printf '%s' "$line" | jq --arg rel "$rel" '.file = $rel')
      all_findings=$(jq --argjson f "$finding" '. + [$f]' <<<"$all_findings")
    fi
  done <<< "$lines"
done <<< "$files"

# Filter by confidence unless --include-medium.
if ! $include_medium; then
  all_findings=$(jq '[.[] | select(.confidence == "high")]' <<<"$all_findings")
fi

high=$(jq '[.[] | select(.confidence == "high")] | length' <<<"$all_findings")
medium=$(jq '[.[] | select(.confidence == "medium")] | length' <<<"$all_findings")
total=$(jq 'length' <<<"$all_findings")

jq -n \
  --arg t "$target" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson findings "$all_findings" \
  --argjson total "$total" \
  --argjson high "$high" \
  --argjson medium "$medium" \
  '{target:$t, scanned_at:$ts, summary:{total:$total, high_confidence:$high, medium_confidence:$medium}, findings:$findings}'
