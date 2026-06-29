#!/usr/bin/env bash
# Guard: iac-apply-confirmation — the destructive-apply gate for I9.
#
# THE critical gate that stands between a destructive IacPlan and a real
# `terraform apply` / `pulumi up` / `cdk deploy` / `helm upgrade` /
# `kubectl apply` / `ansible-playbook`. Invoked by bin/iac-apply.sh AFTER the
# --apply check, with the normalized IacPlan and the operator's gate flags.
#
# Invocation:
#   bash iac-apply-confirmation.sh --plan <iacplan.json> \
#        [--confirm-destroy true|false] [--confirmed true|false]
#
#   --plan            path to the IacPlan JSON emitted by bin/iac-plan.sh.
#   --confirm-destroy whether the operator passed --confirm-destroy to apply.
#   --confirmed       whether the skill layer obtained an explicit interactive
#                     AskUserQuestion confirmation (defaults to the value of
#                     --confirm-destroy when omitted, so the CLI flag alone is
#                     sufficient for headless/scripted use but the skill can
#                     supply a separate signal).
#
# Emits a GuardResult item to stdout:
#   {name:"iac-apply-confirmation", pass:bool, severity:"critical",
#    [skipped:true], message:"..."}
#
# Semantics:
#   - Non-destructive plan (destructive:false): the gate is a no-op → pass,
#     message "not-required". apply proceeds (its --apply check already ran).
#   - Destructive plan (destructive:true — includes advisory tools whose
#     destructive_known is false, treated as potentially-destructive):
#       pass ONLY when --confirm-destroy true AND --confirmed true.
#       Otherwise FAIL (critical) — no single flag can authorize a destructive
#       apply. iac-apply.sh refuses on a failed gate.
#
# nyann handles NO credentials here: the guard reads only the credential-free
# IacPlan summary, never the raw plan/state.
set -o nounset
set -o pipefail

plan_file=""
confirm_destroy="false"
confirmed=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)             plan_file="${2-}"; shift 2 ;;
    --plan=*)           plan_file="${1#--plan=}"; shift ;;
    --confirm-destroy)  confirm_destroy="${2-}"; shift 2 ;;
    --confirm-destroy=*) confirm_destroy="${1#--confirm-destroy=}"; shift ;;
    --confirmed)        confirmed="${2-}"; shift 2 ;;
    --confirmed=*)      confirmed="${1#--confirmed=}"; shift ;;
    *) shift ;;  # tolerate unknown args so the orchestrator can pass extras
  esac
done

# When --confirmed is omitted, the flag alone authorizes (headless parity).
[[ -z "$confirmed" ]] && confirmed="$confirm_destroy"

sev="critical"
emit() {
  # emit <pass:true|false> <message> [<verdict>]
  local pass="$1" message="$2" verdict="${3-}"
  if [[ "$verdict" == "not-required" ]]; then
    jq -n --argjson pass "$pass" --arg sev "$sev" --arg msg "$message" \
      '{name:"iac-apply-confirmation", pass:$pass, severity:$sev, skipped:true, message:$msg}'
  else
    jq -n --argjson pass "$pass" --arg sev "$sev" --arg msg "$message" \
      '{name:"iac-apply-confirmation", pass:$pass, severity:$sev, message:$msg}'
  fi
}

command -v jq >/dev/null 2>&1 || { printf '[nyann] error: jq not installed\n' >&2; exit 1; }

if [[ -z "$plan_file" || ! -f "$plan_file" ]]; then
  # No plan to evaluate ⇒ cannot prove safety ⇒ FAIL closed.
  emit false "no IacPlan provided — refusing to authorize apply"
  exit 0
fi

# FAIL CLOSED on an empty / whitespace-only / unparseable plan. A 0-byte file
# makes `jq -r 'if ... then "true" else "false"'` exit 0 with NO output, so the
# `destructive=""` would fall through to the non-destructive branch and the gate
# would PASS (gate-not-required) — a fail-OPEN hole on the most critical gate.
# Require a non-empty file that parses to a JSON object before trusting any
# field below; anything else cannot prove safety ⇒ refuse.
if [[ ! -s "$plan_file" ]] || ! jq -e 'type == "object"' "$plan_file" >/dev/null 2>&1; then
  emit false "IacPlan is empty or not a JSON object — cannot prove safety, refusing to authorize apply"
  exit 0
fi

# DEFENSIVE: do not trust .destructive alone — a crafted plan claiming
# {summary.destroy:9, destructive:false} must NOT slip past this gate. A plan
# is destructive if it says so, OR has a destroy count, OR destructiveness is
# not provably known. Defaults to "true" (fail closed) on any parse error.
destructive=$(jq -r 'if (.destructive == true) or ((.summary.destroy // 0) > 0) or (.destructive_known != true) then "true" else "false" end' "$plan_file" 2>/dev/null || echo "true")

if [[ "$destructive" != "true" ]]; then
  emit true "plan is non-destructive — destructive-apply gate not required" "not-required"
  exit 0
fi

# Destructive: require BOTH the explicit flag AND the confirmation signal.
if [[ "$confirm_destroy" == "true" && "$confirmed" == "true" ]]; then
  destroy=$(jq -r '.summary.destroy // 0' "$plan_file" 2>/dev/null || echo 0)
  known=$(jq -r 'if .destructive_known == true then "true" else "false" end' "$plan_file" 2>/dev/null || echo "false")
  if [[ "$known" == "true" ]]; then
    emit true "destructive apply confirmed ($destroy resource(s) to destroy/replace)"
  else
    emit true "potentially-destructive apply confirmed (advisory plan — destroy count unknown)"
  fi
  exit 0
fi

emit false "destructive plan requires --confirm-destroy AND explicit confirmation — refusing apply"
exit 0
