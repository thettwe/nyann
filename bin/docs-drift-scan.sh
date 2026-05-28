#!/usr/bin/env bash
# docs-drift-scan.sh — orchestrate doc-drift detection across the four
# detectors (version-refs, file-refs, script-refs, count-claims).
#
# Usage:
#   docs-drift-scan.sh [--target <dir>] [--profile <file>] [--files <csv>]
#                      [--detectors <csv>]
#
# Default scanned files: README.md, CONTRIBUTING.md, SECURITY.md, docs/*.md
# (when present). Profile may override via documentation.drift_check
# .scanned_files[].
#
# Emits DocsDriftReport JSON on stdout. Exits 0 always (advisory) — the
# caller decides whether to gate.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_file=""
files_override=""
detectors_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --profile)    profile_file="${2-}"; shift 2 ;;
    --profile=*)  profile_file="${1#--profile=}"; shift ;;
    --files)      files_override="${2-}"; shift 2 ;;
    --files=*)    files_override="${1#--files=}"; shift ;;
    --detectors)  detectors_override="${2-}"; shift 2 ;;
    --detectors=*) detectors_override="${1#--detectors=}"; shift ;;
    -h|--help)    sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
cd "$target" || nyann::die "cd $target failed"

# Resolve scanned files list.
declare -a scanned=()
if [[ -n "$files_override" ]]; then
  IFS=','
  for f in $files_override; do scanned+=("$f"); done
  unset IFS
elif [[ -n "$profile_file" && -f "$profile_file" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && scanned+=("$f")
  done < <( jq -r '.documentation.drift_check.scanned_files // [] | .[]' "$profile_file" 2>/dev/null )
fi
if (( ${#scanned[@]} == 0 )); then
  for d in README.md CONTRIBUTING.md SECURITY.md; do
    [[ -f "$d" ]] && scanned+=("$d")
  done
  if [[ -d docs ]]; then
    while IFS= read -r f; do
      scanned+=("$f")
    done < <( find docs -maxdepth 2 -type f -name '*.md' 2>/dev/null )
  fi
fi

# Resolve detector list.
declare -a detectors=()
if [[ -n "$detectors_override" ]]; then
  IFS=','
  for d in $detectors_override; do detectors+=("$d"); done
  unset IFS
else
  detectors=( version-refs file-refs script-refs count-claims )
fi

# Profile per-detector toggles.
detector_enabled() {
  local d="$1"
  if [[ -z "$profile_file" || ! -f "$profile_file" ]]; then
    return 0
  fi
  local key
  case "$d" in
    version-refs) key="version_refs" ;;
    file-refs)    key="file_refs" ;;
    script-refs)  key="script_refs" ;;
    count-claims) key="count_claims" ;;
    *) return 0 ;;
  esac
  local flag
  flag=$(jq -r --arg k "$key" 'if .documentation.drift_check[$k].enabled == false then "false" else "true" end' "$profile_file" 2>/dev/null)
  [[ "$flag" != "false" ]]
}

# Master switch.
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  # `// true` is wrong here because jq's `//` treats literal false as
  # null-equivalent (same gotcha as in session-triage). Use an explicit
  # if-equals-false check so the master switch actually blocks.
  master=$(jq -r 'if .documentation.drift_check.enabled == false then "false" else "true" end' "$profile_file" 2>/dev/null)
  if [[ "$master" == "false" ]]; then
    jq -n --arg t "$target" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      target:$t, scanned_at:$ts, scanned_files:[],
      summary:{total:0, by_severity:{critical:0,high:0,medium:0,low:0}, by_kind:{}},
      findings:[]
    }'
    exit 0
  fi
fi

latest_tag=$( git describe --tags --abbrev=0 2>/dev/null || echo "" )

findings_tmp=$(mktemp -t nyann-drift.XXXXXX)
trap 'rm -f "$findings_tmp"' EXIT
: > "$findings_tmp"

for f in "${scanned[@]}"; do
  [[ -f "$target/$f" ]] || continue
  for d in "${detectors[@]}"; do
    detector_enabled "$d" || continue
    script="${_script_dir}/docs-drift/${d}.sh"
    [[ -x "$script" || -f "$script" ]] || continue
    case "$d" in
      version-refs)
        bash "$script" --target "$target" --file "$f" --latest-tag "$latest_tag" >> "$findings_tmp" 2>/dev/null || true
        ;;
      count-claims)
        [[ -n "$profile_file" ]] && bash "$script" --target "$target" --file "$f" --profile "$profile_file" >> "$findings_tmp" 2>/dev/null || true
        ;;
      *)
        bash "$script" --target "$target" --file "$f" >> "$findings_tmp" 2>/dev/null || true
        ;;
    esac
  done
done

# Aggregate.
all_findings='[]'
if [[ -s "$findings_tmp" ]]; then
  all_findings=$(jq -s '.' < "$findings_tmp")
fi

total=$(jq 'length' <<<"$all_findings")
crit=$(  jq '[.[] | select(.severity == "critical")] | length' <<<"$all_findings")
high=$(  jq '[.[] | select(.severity == "high")] | length'     <<<"$all_findings")
med=$(   jq '[.[] | select(.severity == "medium")] | length'   <<<"$all_findings")
low=$(   jq '[.[] | select(.severity == "low")] | length'      <<<"$all_findings")
by_kind=$(jq '[.[] | .kind] | group_by(.) | map({(.[0]): length}) | add // {}' <<<"$all_findings")

scanned_json=$(printf '%s\n' "${scanned[@]}" | jq -R . | jq -s .)

jq -n \
  --arg t "$target" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson scanned "$scanned_json" \
  --argjson total "$total" \
  --argjson crit "$crit" \
  --argjson high "$high" \
  --argjson med "$med" \
  --argjson low "$low" \
  --argjson by_kind "$by_kind" \
  --argjson findings "$all_findings" \
  '{target:$t, scanned_at:$ts, scanned_files:$scanned,
    summary:{total:$total, by_severity:{critical:$crit, high:$high, medium:$med, low:$low}, by_kind:$by_kind},
    findings:$findings}'
