#!/usr/bin/env bash
# Guard: license-allowlist — warn (ADVISORY) when dependency licenses fall
# outside the profile's security.license_check.allowlist.
#
# OPT-IN. Off by default: it is NOT in any flow's builtin_guards list in
# pre-action-guard.sh — it runs only when a profile names it in
# `guards.pr` / `guards.ship` / `guards.release`, and only does real work
# when `security.license_check.enabled` is true. Advisory by default; a
# profile promotes it via the guards.<flow>[].severity lever.
#
# Positional contract (invoked by pre-action-guard.sh):
#     license-allowlist.sh <target> <base> [<profile.json>]
# <base> is part of the contract but unused (licenses are a working-tree
# property, not a diff property). Emits ONE GuardResult fragment to stdout
# and ALWAYS exits 0 — exit codes 3/4 are pre-action-guard's job.
#
# The scan itself (bin/license-scan.sh) is filesystem + locally-installed
# ecosystem tools only; when no collector applies (tools not installed,
# no manifests) the guard reports a SKIP, never a failure — posture
# tooling must not block people who haven't installed it.

_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="${1-$PWD}"
# shellcheck disable=SC2034  # positional contract slot
base="${2:-main}"
profile="${3-}"

command -v jq >/dev/null 2>&1 || {
  echo '{"name":"license-allowlist","pass":true,"severity":"advisory","skipped":true,"message":"jq unavailable — skipped"}'
  exit 0
}

if [[ -z "$profile" || ! -f "$profile" ]] \
   || [[ "$(jq -r '.security.license_check.enabled // false' "$profile" 2>/dev/null)" != "true" ]]; then
  jq -n '{name:"license-allowlist", pass:true, severity:"advisory", skipped:true,
          message:"license_check not enabled in profile — skipped"}'
  exit 0
fi

report=$(bash "${_guard_dir}/../license-scan.sh" --target "$target" --profile "$profile" 2>/dev/null) || report=""
if ! jq -e 'type == "object" and has("summary")' >/dev/null 2>&1 <<<"$report"; then
  jq -n '{name:"license-allowlist", pass:true, severity:"advisory", skipped:true,
          message:"license scan unavailable — skipped"}'
  exit 0
fi

scanned=$(jq -r '.scanned' <<<"$report")
if [[ "$scanned" != "true" ]]; then
  jq -n '{name:"license-allowlist", pass:true, severity:"advisory", skipped:true,
          message:"no license collector applicable (ecosystem tools not installed) — skipped"}'
  exit 0
fi

violations=$(jq -r '.summary.violations' <<<"$report")
if [[ "$violations" == "0" ]]; then
  jq --argjson total "$(jq '.packages_total' <<<"$report")" -n \
    '{name:"license-allowlist", pass:true, severity:"advisory",
      message:"\($total) package license(s) within the allowlist"}'
else
  # Name the first few offenders in the message so the nudge is actionable
  # without a second command.
  jq -n --argjson v "$violations" \
    --arg head "$(jq -r '[.violations[0:3][] | "\(.package) (\(.license // "?"))"] | join(", ")' <<<"$report")" \
    '{name:"license-allowlist", pass:false, severity:"advisory",
      message:"\($v) package(s) outside the license allowlist — e.g. \($head). bin/license-scan.sh for the full report"}'
fi
exit 0
