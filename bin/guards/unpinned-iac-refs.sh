#!/usr/bin/env bash
# Guard: no unpinned IaC refs in the working tree. Advisory base severity
# (promotable to confirm/critical via profile.guards.<flow>). Registered for
# the commit + release flows.
#
# Thin adapter over bin/iac-drift/unpinned-refs.sh — it does NOT re-implement
# IaC discovery. It runs the shared iac-drift scanner restricted to the
# unpinned-refs detector, counts findings, and emits a GuardResult item. One
# detector subsystem feeds doctor, the DriftReport probe, and this guard, so
# scan logic lives in exactly one place (no duplication).
#
# Invocation (by bin/pre-action-guard.sh): `bash unpinned-iac-refs.sh <target>
# <base> [<profile.json>]`. base is ignored. The optional 3rd positional arg
# is the resolved profile JSON path — when present its iac.drift_check flags
# gate the guard (master enabled=false OR unpinned_refs=false → soft-skip).
#
# Soft-skip (pass:true, skipped:true) on: not a git repo, profile-disabled, or
# a repo with no IaC files — so the guard stays silent for the ~90% of repos
# that aren't infra.
target="${1-$PWD}"
# $2 (base) intentionally unused.
profile_file="${3-}"

_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scanner="${_guard_dir}/../iac-drift-scan.sh"
sev="advisory"

emit() {
  # emit <pass:true|false> <message> [<skipped:true>]
  local pass="$1" message="$2" skipped="${3-}"
  if [[ -n "$skipped" ]]; then
    jq -n --arg name "unpinned-iac-refs" --argjson pass "$pass" --arg sev "$sev" --arg msg "$message" \
      '{name:$name,pass:$pass,severity:$sev,skipped:true,message:$msg}'
  else
    jq -n --arg name "unpinned-iac-refs" --argjson pass "$pass" --arg sev "$sev" --arg msg "$message" \
      '{name:$name,pass:$pass,severity:$sev,message:$msg}'
  fi
}

command -v jq >/dev/null 2>&1 || exit 1

# Soft-skip outside a git work tree — there is nothing committed to govern.
if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit true "not a git repository — skipped" true
  exit 0
fi

# Profile gating: master enabled=false OR unpinned_refs=false disables the
# guard. Explicit `== false` test (NOT jq `//`) because `//` treats a literal
# false as null-equivalent and would leave a disabled flag enabled.
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  disabled=$(jq -r '
    if (.iac.drift_check.enabled == false) or (.iac.drift_check.unpinned_refs == false)
    then "true" else "false" end' "$profile_file" 2>/dev/null || echo "false")
  if [[ "$disabled" == "true" ]]; then
    emit true "unpinned-refs detector disabled by profile — skipped" true
    exit 0
  fi
fi

[[ -x "$scanner" || -f "$scanner" ]] || { emit true "iac-drift scanner unavailable — skipped" true; exit 0; }

# Run the shared scanner restricted to the unpinned-refs detector. Always
# exits 0 (advisory); we read findings from the JSON.
report=$(bash "$scanner" --target "$target" --detectors unpinned-refs 2>/dev/null || echo '{}')
if [[ "$(jq -r 'type' <<<"$report" 2>/dev/null || echo "")" != "object" ]]; then
  report='{}'
fi

n=$(jq -r '[.findings[]? | select(.kind == "unpinned-ref")] | length' <<<"$report" 2>/dev/null || echo 0)
[[ "$n" =~ ^[0-9]+$ ]] || n=0

if (( n == 0 )); then
  emit true "no unpinned IaC refs"
  exit 0
fi

# Surface the first couple of offending files inline so the advisory is
# actionable without re-running the scanner.
detail=$(jq -r '[.findings[]? | select(.kind == "unpinned-ref") | .file + (if .line then ":\(.line)" else "" end)] | unique | .[0:3] | join(", ")' <<<"$report" 2>/dev/null || echo "")
emit false "$n unpinned IaC ref(s) (moving module ref / unpinned provider / unpinned dep) — pin to a tag/SHA${detail:+ — e.g. $detail}"
exit 0
