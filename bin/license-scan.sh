#!/usr/bin/env bash
# license-scan.sh — cross-stack dependency-license inventory + allowlist check.
#
# Usage:
#   license-scan.sh --target <repo> [--profile <path>] [--tools-dir <dir>]
#
# Dispatches to the per-stack collectors under bin/license-tools/ (js /
# python / go / rust — each soft-skips when its manifest or CLI is absent),
# merges the normalized {package, version, license} rows, and evaluates the
# profile's security.license_check allowlist. Emits a LicenseScanReport
# (schemas/license-scan-report.schema.json) on stdout. Log lines → stderr.
#
# This is an ALLOWLIST NUDGE, complementary to (not replacing) real SCA
# products: filesystem + locally-installed tools only, no network, no
# installs, and it never blocks anything by itself — the opt-in
# license-allowlist guard and the doctor section carry the findings at
# advisory severity.
#
# Allowlist semantics (conservative — never guess an undeclared license):
#   * License strings are trimmed and stripped of surrounding parens.
#   * `A OR B` passes when ANY branch passes (that is what a disjunctive
#     license grant means); `A AND B` requires EVERY part to pass.
#   * Empty / UNKNOWN / UNLICENSED → a violation with reason
#     "unknown-license" (distinct from "not-allowlisted").
#   * security.license_check.ignore_packages[] exempts by exact name.
#
# Exit codes: 0 whenever a report was produced (violations INCLUDED — the
# findings live in the JSON so doctor's `|| echo '{}'` probe guard never
# discards them); 1 on hard errors only. When the profile disables the
# check (or no profile is given and no collector applies) the report says
# so and the scan is a cheap no-op.
#
# Requires jq.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
tools_dir="${_script_dir}/license-tools"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="${2-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --profile)     profile_path="${2-}"; shift 2 ;;
    --profile=*)   profile_path="${1#--profile=}"; shift ;;
    --tools-dir)   tools_dir="${2-}"; shift 2 ;;
    --tools-dir=*) tools_dir="${1#--tools-dir=}"; shift ;;
    -h|--help)     sed -n '3,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"

# --- Config (schema defaults when no profile / block absent) -----------------

enabled=false
allowlist='["MIT","Apache-2.0","BSD-2-Clause","BSD-3-Clause","ISC","0BSD","Unlicense"]'
ignore='[]'
if [[ -n "$profile_path" && -f "$profile_path" ]]; then
  enabled=$(jq -r '.security.license_check.enabled // false' "$profile_path" 2>/dev/null || echo false)
  al=$(jq -c '.security.license_check.allowlist // empty' "$profile_path" 2>/dev/null || true)
  [[ -n "$al" ]] && allowlist="$al"
  ig=$(jq -c '.security.license_check.ignore_packages // empty' "$profile_path" 2>/dev/null || true)
  [[ -n "$ig" ]] && ignore="$ig"
fi

if [[ "$enabled" != "true" ]]; then
  jq -n '{enabled: false, scanned: false, tools_run: [], tools_skipped: [],
          packages_total: 0, violations: [],
          summary: {total: 0, violations: 0, by_reason: {}}}'
  exit 0
fi

# --- Collect -----------------------------------------------------------------

rows='[]'
tools_run=()
tools_skipped=()
for tool in js python go rust; do
  tool_script="${tools_dir}/${tool}.sh"
  [[ -f "$tool_script" ]] || { tools_skipped+=("$tool"); continue; }
  if out=$(bash "$tool_script" "$target" 2>/dev/null) \
     && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
    rows=$(jq --argjson new "$out" --arg t "$tool" \
      '. + ($new | map(. + {tool: $t}))' <<<"$rows")
    tools_run+=("$tool")
  else
    tools_skipped+=("$tool")
  fi
done

run_json=$(printf '%s\n' "${tools_run[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')
skip_json=$(printf '%s\n' "${tools_skipped[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')

# --- Evaluate the allowlist ---------------------------------------------------
# OR: any branch allowed → allowed. AND: every part must be allowed.
# Unknown/empty → "unknown-license". Exemptions by exact package name.

report=$(jq -n \
  --argjson rows "$rows" \
  --argjson allow "$allowlist" \
  --argjson ignore "$ignore" \
  --argjson run "$run_json" \
  --argjson skipped "$skip_json" '
  def norm: gsub("^\\s+|\\s+$"; "") | gsub("^\\(|\\)$"; "");
  def branch_ok($allow): norm as $b |
    ($b | split(" AND ")) | all(. as $part | ($allow | index($part | norm)) != null);
  def license_ok($allow): norm as $l |
    ($l | split(" OR ")) | any(. as $br | ($br | branch_ok($allow)));
  ($rows | map(select(.package as $p | ($ignore | index($p)) == null))) as $checked |
  ($checked | map(
     (.license // "" | norm) as $l |
     if ($l == "" or ($l | ascii_upcase) == "UNKNOWN" or ($l | ascii_upcase) == "UNLICENSED")
     then . + {reason: "unknown-license"}
     elif ($l | license_ok($allow)) | not
     then . + {reason: "not-allowlisted"}
     else empty end)) as $violations |
  {enabled: true,
   scanned: (($run | length) > 0),
   tools_run: $run,
   tools_skipped: $skipped,
   packages_total: ($rows | length),
   violations: $violations,
   summary: {
     total: ($rows | length),
     violations: ($violations | length),
     by_reason: ($violations | group_by(.reason) | map({(.[0].reason): length}) | add // {})
   }}')

count=$(jq -r '.summary.violations' <<<"$report")
if [[ "$count" != "0" ]]; then
  nyann::warn "license-scan: $count package(s) outside the allowlist"
else
  nyann::log "license-scan: clean ($(jq -r '.packages_total' <<<"$report") packages, tools: $(jq -r '.tools_run | join(",")' <<<"$report"))"
fi
printf '%s\n' "$report"
exit 0
