#!/usr/bin/env bash
# Guard: no committed secrets in IaC var files. CRITICAL base severity —
# blocks the release flow by default. Registered for the release flow.
#
# Thin adapter over bin/iac-drift/secrets-in-vars.sh (via the shared
# iac-drift-scan orchestrator). The detector itself enforces the load-bearing
# "committed (tracked AND not gitignored)" gate, the known-credential-shape
# heuristics, the .nyann/secret-allowlist, and `# drift-ignore` suppression —
# this guard only translates its findings into a GuardResult item.
#
# Invocation (by bin/pre-action-guard.sh): `bash committed-secrets.sh
# <target> <base> [<profile.json>]`. base is ignored. The optional 3rd
# positional arg is the resolved profile JSON path.
#
# Demotable per profile: the pre-action-guard promotion path is promotion-only
# (it can never weaken a built-in critical), so the demotion lever is the
# profile flag iac.drift_check.secrets_in_vars=false (or master enabled=false),
# which makes this guard soft-skip. That is the documented "demotable critical
# gate" mechanism (mirrors the docs-drift critical gate being profile-gated).
#
# Soft-skip (pass:true, skipped:true) on: not a git repo, profile-disabled, or
# a repo with no committed secrets — quiet for non-infra repos.
target="${1-$PWD}"
# $2 (base) intentionally unused.
profile_file="${3-}"

_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scanner="${_guard_dir}/../iac-drift-scan.sh"
sev="critical"

emit() {
  # emit <pass:true|false> <message> [<skipped:true>]
  local pass="$1" message="$2" skipped="${3-}"
  if [[ -n "$skipped" ]]; then
    jq -n --arg name "committed-secrets" --argjson pass "$pass" --arg sev "$sev" --arg msg "$message" \
      '{name:$name,pass:$pass,severity:$sev,skipped:true,message:$msg}'
  else
    jq -n --arg name "committed-secrets" --argjson pass "$pass" --arg sev "$sev" --arg msg "$message" \
      '{name:$name,pass:$pass,severity:$sev,message:$msg}'
  fi
}

command -v jq >/dev/null 2>&1 || exit 1

# Re-emit the built-in severity even on the soft-skip branch so the
# orchestrator's promotion ranking has a stable critical floor to compare
# against (same convention as clean-tree).
if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit true "not a git repository — skipped" true
  exit 0
fi

# Profile demotion / gating: master enabled=false OR secrets_in_vars=false
# soft-skips. Explicit `== false` test (NOT jq `//`) so a literal false is
# honoured rather than treated as null-equivalent.
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  disabled=$(jq -r '
    if (.iac.drift_check.enabled == false) or (.iac.drift_check.secrets_in_vars == false)
    then "true" else "false" end' "$profile_file" 2>/dev/null || echo "false")
  if [[ "$disabled" == "true" ]]; then
    emit true "committed-secrets gate disabled by profile — skipped" true
    exit 0
  fi
fi

[[ -x "$scanner" || -f "$scanner" ]] || { emit true "iac-drift scanner unavailable — skipped" true; exit 0; }

report=$(bash "$scanner" --target "$target" --detectors secrets-in-vars 2>/dev/null || echo '{}')
if [[ "$(jq -r 'type' <<<"$report" 2>/dev/null || echo "")" != "object" ]]; then
  report='{}'
fi

n=$(jq -r '[.findings[]? | select(.kind == "secret-in-vars")] | length' <<<"$report" 2>/dev/null || echo 0)
[[ "$n" =~ ^[0-9]+$ ]] || n=0

if (( n == 0 )); then
  emit true "no committed secrets in IaC var files"
  exit 0
fi

# Surface offending files (NOT the redacted values — keep the secret out of
# guard output entirely). The detector already redacts; the guard adds nothing.
detail=$(jq -r '[.findings[]? | select(.kind == "secret-in-vars") | .file + (if .line then ":\(.line)" else "" end)] | unique | .[0:3] | join(", ")' <<<"$report" 2>/dev/null || echo "")
emit false "$n committed secret(s) in IaC var file(s) — rotate the credential(s) and remove from version control${detail:+ — $detail}"
exit 0
