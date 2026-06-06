#!/usr/bin/env bash
# iac-drift-scan.sh — orchestrate IaC-drift detection across the four
# detectors (unpinned-refs, missing-lockfile, secrets-in-vars, version-lag).
#
# Usage:
#   iac-drift-scan.sh [--target <dir>] [--profile <file>] [--files <csv>]
#                     [--detectors <csv>]
#
# Default scanned set: Terraform (*.tf), Helm (Chart.yaml), CDK/Pulumi
# (package.json / Pulumi.yaml / requirements.txt), and var files
# (*.tfvars, Pulumi.<stack>.yaml, Ansible group_vars/host_vars/*vault*).
# Profile may override via iac.drift_check.scanned_files[].
#
# Filesystem + git only — no `terraform plan`, no cloud CLI, no network.
#
# Emits IacDriftReport JSON on stdout. Exits 0 always (advisory) — the
# caller (doctor / guards) decides whether to gate.

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
    --target)      target="${2-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --profile)     profile_file="${2-}"; shift 2 ;;
    --profile=*)   profile_file="${1#--profile=}"; shift ;;
    --files)       files_override="${2-}"; shift 2 ;;
    --files=*)     files_override="${1#--files=}"; shift ;;
    --detectors)   detectors_override="${2-}"; shift 2 ;;
    --detectors=*) detectors_override="${1#--detectors=}"; shift ;;
    -h|--help)     sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
cd "$target" || nyann::die "cd $target failed"

# Resolve the scanned-files list. IaC files live anywhere in the tree
# (unlike docs which cluster in docs/), so the default is a multi-pattern
# `find` rather than a fixed top-level set. The .terraform/ working dir and
# .git are pruned because they hold downloaded/derived state, not source.
declare -a scanned=()
if [[ -n "$files_override" ]]; then
  IFS=','
  for f in $files_override; do scanned+=("$f"); done
  unset IFS
elif [[ -n "$profile_file" && -f "$profile_file" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && scanned+=("$f")
  done < <( jq -r '.iac.drift_check.scanned_files // [] | .[]' "$profile_file" 2>/dev/null )
fi
if (( ${#scanned[@]} == 0 )); then
  while IFS= read -r f; do
    f="${f#./}"
    scanned+=("$f")
  done < <(
    find . \
      \( -path '*/.git' -o -path '*/.terraform' -o -path '*/node_modules' -o -path '*/.git/*' -o -path '*/.terraform/*' -o -path '*/node_modules/*' \) -prune -o \
      -type f \
      \( -name '*.tf' \
         -o -name 'Chart.yaml' \
         -o -name 'Pulumi.yaml' -o -name 'Pulumi.yml' \
         -o -name 'Pulumi.*.yaml' -o -name 'Pulumi.*.yml' \
         -o -name '*.tfvars' -o -name '*.tfvars.json' \
         -o -name 'package.json' \
         -o -name 'requirements.txt' \) \
      -print 2>/dev/null
  )
  # Ansible vars/vault files don't match a tidy extension. Add the common
  # locations explicitly so secrets-in-vars can reach them.
  while IFS= read -r f; do
    f="${f#./}"
    scanned+=("$f")
  done < <(
    find . \
      \( -path '*/.git' -o -path '*/.git/*' -o -path '*/node_modules' -o -path '*/node_modules/*' \) -prune -o \
      -type f \
      \( -path '*/group_vars/*' -o -path '*/host_vars/*' -o -name '*vault*.yml' -o -name '*vault*.yaml' \) \
      -print 2>/dev/null
  )
fi

# Resolve detector list.
declare -a detectors=()
if [[ -n "$detectors_override" ]]; then
  IFS=','
  for d in $detectors_override; do detectors+=("$d"); done
  unset IFS
else
  detectors=( unpinned-refs missing-lockfile secrets-in-vars version-lag )
fi

# Profile per-detector toggles. Maps detector name → the flat boolean key in
# iac.drift_check (unpinned-refs → unpinned_refs, etc.). Mirrors the
# documentation.readme_badges flat-boolean style chosen for I8 in the spec.
detector_enabled() {
  local d="$1"
  if [[ -z "$profile_file" || ! -f "$profile_file" ]]; then
    return 0
  fi
  local key
  case "$d" in
    unpinned-refs)    key="unpinned_refs" ;;
    missing-lockfile) key="missing_lockfile" ;;
    secrets-in-vars)  key="secrets_in_vars" ;;
    version-lag)      key="version_lag" ;;
    *) return 0 ;;
  esac
  local flag
  # Flat boolean: iac.drift_check.<key> == false disables. Use an explicit
  # if-equals-false check (NOT jq `//`) — `//` treats literal false as
  # null-equivalent and would wrongly leave a disabled detector enabled.
  flag=$(jq -r --arg k "$key" 'if .iac.drift_check[$k] == false then "false" else "true" end' "$profile_file" 2>/dev/null)
  [[ "$flag" != "false" ]]
}

# Master switch. iac.drift_check.enabled == false → empty report, exit early.
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  master=$(jq -r 'if .iac.drift_check.enabled == false then "false" else "true" end' "$profile_file" 2>/dev/null)
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

findings_tmp=$(mktemp -t nyann-iac-drift.XXXXXX)
trap 'rm -f "$findings_tmp"' EXIT
: > "$findings_tmp"

if (( ${#scanned[@]} )); then
for f in "${scanned[@]}"; do
  [[ -f "$target/$f" ]] || continue
  for d in "${detectors[@]}"; do
    detector_enabled "$d" || continue
    script="${_script_dir}/iac-drift/${d}.sh"
    [[ -x "$script" || -f "$script" ]] || continue
    case "$d" in
      version-lag)
        # version-lag compares Helm appVersion / module versions against the
        # latest git tag, so it needs the resolved tag passed through.
        bash "$script" --target "$target" --file "$f" --latest-tag "$latest_tag" >> "$findings_tmp" 2>/dev/null || true
        ;;
      *)
        bash "$script" --target "$target" --file "$f" >> "$findings_tmp" 2>/dev/null || true
        ;;
    esac
  done
done
fi

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

scanned_json='[]'
if (( ${#scanned[@]} )); then
  scanned_json=$(printf '%s\n' "${scanned[@]}" | jq -R . | jq -s .)
fi

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
