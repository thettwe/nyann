#!/usr/bin/env bash
# check-claude-md-size.sh — verify CLAUDE.md fits the profile's soft budget.
#
# Usage: check-claude-md-size.sh --target <repo> --profile <path>
#
# Thresholds:
#   bytes <=   budget                          → ok
#   budget <   bytes <= NYANN_CLAUDEMD_HARD_CAP → warn
#   bytes >    NYANN_CLAUDEMD_HARD_CAP          → error (suggests extraction)
#
# The soft cap is profile-configurable; the hard cap is a plugin-wide
# constant (see bin/_lib.sh). These thresholds must match gen-claudemd
# exactly, otherwise a file the writer considers valid can be reported
# as "critical" by doctor / retrofit.
#
# Output: JSON on stdout. If CLAUDE.md is absent, emits {status:"absent"}.
#
# The recommendation text lists each `##` section heading with its byte
# count, so the reader can pick the largest to extract into a linked doc.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2:-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --profile)   profile_path="${2:-}"; shift 2 ;;
    --profile=*) profile_path="${1#--profile=}"; shift ;;
    -h|--help)   sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile is required"
target="$(cd "$target" && pwd)"

path="$target/CLAUDE.md"
budget_kb=$(jq '.documentation.claude_md_size_budget_kb // 3' "$profile_path")
# Use `awk -v` so the profile-supplied value is always a variable
# rather than embedded code. Earlier the value was interpolated into
# the awk program string, which let a hand-crafted profile smuggle in
# `system(...)` calls if schema validation hadn't run first.
budget_bytes=$(awk -v kb="$budget_kb" 'BEGIN{printf "%d", kb * 1024}')

if [[ ! -f "$path" ]]; then
  jq -n --argjson budget "$budget_bytes" \
    '{ path: "CLAUDE.md", status: "absent", budget_bytes: $budget, bytes: 0 }'
  exit 0
fi

bytes=$(wc -c < "$path" | tr -d ' ')

# Find top-level `## ` sections and report byte-size per section so the
# recommendation can point at the largest extract candidates. python3 is
# the cleanest way to do this; when it's absent we degrade to an empty
# sections list (status + bytes + budget still reported).
if nyann::has_cmd python3; then
  sections_json=$(python3 - "$path" <<'PY'
import json, re, sys

text = open(sys.argv[1], 'rb').read()
matches = list(re.finditer(rb'(?m)^##\s+(.+)$', text))
sections = []
for i, m in enumerate(matches):
    start = m.start()
    end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
    size = end - start
    title = m.group(1).decode('utf-8', errors='replace').strip()
    sections.append({"title": title, "bytes": size})
sections.sort(key=lambda s: s['bytes'], reverse=True)
print(json.dumps(sections))
PY
  )
else
  sections_json='[]'
fi

# Hard cap is plugin-wide (NYANN_CLAUDEMD_HARD_CAP_BYTES in _lib.sh)
# rather than the old `budget_bytes * 2` formula. That formula produced
# a 6144-byte hard cap for a 3-KB budget, contradicting gen-claudemd's
# fixed 8192 — a file the writer happily accepted could then be flagged
# "error" by doctor/retrofit, producing a false critical in the
# DriftReport. Both scripts now read the same constant.
hard_bytes="$NYANN_CLAUDEMD_HARD_CAP_BYTES"
status="ok"
if (( bytes > hard_bytes )); then
  status="error"
elif (( bytes > budget_bytes )); then
  status="warn"
fi

recommendation=""
if [[ "$status" != "ok" ]]; then
  top=$(jq -r '.[0:3] | map("- \(.title) (\(.bytes) B)") | join("\n")' <<<"$sections_json")
  if [[ -n "$top" && "$top" != "null" ]]; then
    recommendation="CLAUDE.md exceeds budget. Largest sections (candidates for extraction into linked docs):"$'\n'"$top"
  else
    recommendation="CLAUDE.md exceeds budget. Extract supporting detail into linked docs and leave CLAUDE.md as a router."
  fi
fi

jq -n \
  --arg path "CLAUDE.md" \
  --argjson bytes "$bytes" \
  --argjson budget "$budget_bytes" \
  --argjson hard "$hard_bytes" \
  --arg status "$status" \
  --arg rec "$recommendation" \
  --argjson sections "$sections_json" \
  '{
    path: $path,
    bytes: $bytes,
    budget_bytes: $budget,
    hard_cap_bytes: $hard,
    status: $status,
    sections: $sections,
    recommendation: $rec
  }'
