#!/usr/bin/env bash
# iac-apply.sh — gated IaC apply orchestrator (I9). THE highest-stakes mutator
# in nyann: it can mutate real cloud infrastructure. Every safety invariant
# below is non-negotiable and enforced in code, not just prose.
#
# Usage:
#   iac-apply.sh [--target <dir>] [--unit <repo-rel-path>]
#                [--apply] [--confirm-destroy] [--confirmed]
#                [--dry-run] [--plan <iacplan.json>]
#
# SAFETY INVARIANTS (mirrors bin/undo.sh's preview-before-mutate gate):
#   1. apply is NEVER the default. Without --apply this script PREVIEWS the
#      plan (status:"preview") and exits 0. It refuses to apply.
#   2. --dry-run wins over --apply: an explicit dry-run always previews.
#   3. When the plan is destructive (summary.destroy > 0, OR an advisory plan
#      whose destructiveness is unknown), apply additionally requires
#      --confirm-destroy AND the iac-apply-confirmation guard must pass. No
#      single flag can authorize a destructive apply.
#   4. nyann NEVER handles credentials. It shells out to the user's already-
#      authenticated CLI. It reads/stores/logs/passes NO secrets/state.
#   5. Soft-skip (status:"skipped", exit 0) when the CLI/backend/creds are
#      absent — never a partial apply.
#
# AUDIT: on a real apply (after all gates pass), writes an IacApplyRecord to
# <target>/memory/.nyann/iac-applies/<ISO-ts>/manifest.json. The record holds
# ONLY metadata (tool, unit, the plan's add/change/destroy summary, the gate
# flags satisfied, the apply command's exit code, the plan sha256). It contains
# NO credentials, NO secrets, NO full state, NO raw plan/state bytes.
#
# Output (stdout JSON):
#   { status:"preview"|"applied"|"skipped"|"refused", tool, unit,
#     summary:{add,change,destroy}, destructive, destructive_known,
#     [record_path], [exit_code], message }

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
unit=""
do_apply=false
confirm_destroy=false
confirmed=""        # explicit interactive confirmation signal from the skill
dry_run=false
plan_file=""        # optional pre-computed IacPlan; else we run iac-plan.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)           target="${2-}"; shift 2 ;;
    --target=*)         target="${1#--target=}"; shift ;;
    --unit)             unit="${2-}"; shift 2 ;;
    --unit=*)           unit="${1#--unit=}"; shift ;;
    --apply)            do_apply=true; shift ;;
    --confirm-destroy)  confirm_destroy=true; shift ;;
    --confirmed)        confirmed=true; shift ;;
    --dry-run)          dry_run=true; shift ;;
    --plan)             plan_file="${2-}"; shift 2 ;;
    --plan=*)           plan_file="${1#--plan=}"; shift ;;
    -h|--help)          sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
target="$(cd "$target" && pwd -P)"

# --- emitters ----------------------------------------------------------------

emit() {
  # emit <status> <plan_json> [<extra_json_object>]
  # NB: default the extra object with a separate assignment, NOT an inline
  # `${3-{}}` — bash parses that as default `{` plus a literal `}`, which
  # appends a stray `}` to a real 3rd arg and corrupts the JSON.
  local status="$1" plan_json="$2" extra="${3:-}"
  [[ -z "$extra" ]] && extra='{}'
  jq -n \
    --arg status "$status" \
    --argjson plan "$plan_json" \
    --argjson extra "$extra" \
    '{
      status:$status,
      tool: ($plan.tool // ""),
      unit: ($plan.unit // "."),
      summary: ($plan.summary // {add:0,change:0,destroy:0}),
      destructive: ($plan.destructive // false),
      destructive_known: ($plan.destructive_known // false)
    } + $extra'
}

# --- obtain the plan ---------------------------------------------------------
# A plan is ALWAYS computed/required first. apply works off the same normalized
# IacPlan the operator previewed — preview-before-mutate end to end.
if [[ -n "$plan_file" ]]; then
  [[ -f "$plan_file" ]] || nyann::die "--plan file not found: $plan_file"
  plan_json="$(cat "$plan_file")"
else
  plan_args=(--target "$target")
  [[ -n "$unit" ]] && plan_args+=(--unit "$unit")
  # iac-plan exits 1 on refusal; capture but don't abort under set -e.
  set +e
  plan_json="$(bash "${_script_dir}/iac-plan.sh" "${plan_args[@]}" 2>/dev/null)"
  set -e
fi

if [[ "$(jq -r 'type' <<<"$plan_json" 2>/dev/null || echo "")" != "object" ]]; then
  nyann::die "could not obtain a valid IacPlan"
fi

plan_status=$(jq -r '.status // ""' <<<"$plan_json")
tool=$(jq -r '.tool // ""' <<<"$plan_json")
unit_label=$(jq -r '.unit // "."' <<<"$plan_json")
destroy=$(jq -r '.summary.destroy // 0' <<<"$plan_json")
# DEFENSIVE destructiveness: never trust the plan's self-reported .destructive
# alone. A crafted or stale --plan file (the save-then-apply workflow) could
# claim {summary.destroy:9, destructive:false} to slip a destroy past the
# confirmation gate. Treat a plan as destructive if ANY of: it says so, the
# destroy count is >0, or destructiveness is not provably known (advisory /
# unknown tools fail safe). A summary.destroy>0 can therefore NEVER be applied
# with a single flag.
destructive=$(jq -r 'if (.destructive == true) or ((.summary.destroy // 0) > 0) or (.destructive_known != true) then "true" else "false" end' <<<"$plan_json")

# Plan soft-skipped (CLI/backend/creds absent) ⇒ apply soft-skips too. NEVER
# partial-apply when we couldn't even preview.
if [[ "$plan_status" == "skipped" ]]; then
  msg=$(jq -r '.message // "plan skipped — CLI or backend/credentials absent"' <<<"$plan_json")
  emit "skipped" "$plan_json" "$(jq -n --arg m "$msg" '{message:$m}')"
  exit 0
fi
if [[ "$plan_status" == "refused" ]]; then
  msg=$(jq -r '.message // "plan refused"' <<<"$plan_json")
  emit "refused" "$plan_json" "$(jq -n --arg m "$msg" '{message:$m}')"
  exit 1
fi

# --- GATE 1: preview-by-default ---------------------------------------------
# --dry-run wins over --apply (explicit dry-run always previews). Without
# --apply we PREVIEW and exit 0 — apply is never the default.
if $dry_run || ! $do_apply; then
  hint="preview only: re-run with --apply to apply"
  if [[ "$destructive" == "true" ]]; then
    hint="$hint (and --confirm-destroy — this plan is DESTRUCTIVE)"
  fi
  nyann::warn "$hint"
  emit "preview" "$plan_json" "$(jq -n --arg m "$hint" '{message:$m}')"
  exit 0
fi

# --- GATE 2: destructive-apply confirmation ---------------------------------
# Only reached when --apply is set and not --dry-run. For a destructive plan,
# require --confirm-destroy AND the confirmation guard to pass. The guard is
# THE critical gate — no single flag authorizes a destructive apply.
guard="${_script_dir}/guards/iac-apply-confirmation.sh"
plan_tmp="$(mktemp -t nyann-iac-applyplan.XXXXXX)"
trap 'rm -f "$plan_tmp"' EXIT
printf '%s' "$plan_json" > "$plan_tmp"

cd_flag="false"; $confirm_destroy && cd_flag="true"
confirmed_flag="$cd_flag"; [[ -n "$confirmed" ]] && confirmed_flag="true"

guard_result="$(bash "$guard" --plan "$plan_tmp" --confirm-destroy "$cd_flag" --confirmed "$confirmed_flag" 2>/dev/null || echo '{}')"
guard_pass=$(jq -r 'if .pass == true then "true" else "false" end' <<<"$guard_result" 2>/dev/null || echo "false")
guard_skipped=$(jq -r 'if .skipped == true then "true" else "false" end' <<<"$guard_result" 2>/dev/null || echo "false")

if [[ "$guard_pass" != "true" ]]; then
  gmsg=$(jq -r '.message // "destructive-apply gate failed"' <<<"$guard_result")
  nyann::warn "refusing apply: $gmsg"
  emit "refused" "$plan_json" "$(jq -n --arg m "$gmsg" '{message:("destructive-apply gate failed — " + $m)}')"
  exit 1
fi

# Guard "pass" verdict for the record: a non-destructive plan yields
# skipped:true (not-required); a destructive plan yields a real pass.
if [[ "$guard_skipped" == "true" ]]; then
  guard_verdict="not-required"
else
  guard_verdict="pass"
fi

# --- resolve the unit dir for the apply command ------------------------------
# Mirror iac-plan.sh's resolution: --unit may point at a stack DESCRIPTOR FILE
# (CDK/Pulumi: cdk.json / Pulumi.yaml / a per-stack file) rather than a dir. The
# apply commands `cd "$unit_dir"`, so when --unit resolves to a file we use its
# containing directory (the traversal guard already vetted the resolved path).
if [[ -n "$unit" ]]; then
  if ! unit_dir="$(nyann::path_under_target "$target" "$target/$unit" 2>/dev/null)"; then
    nyann::die "--unit escapes target directory: $unit"
  fi
  if [[ -f "$unit_dir" ]]; then
    unit_dir="$(dirname "$unit_dir")"
  elif [[ ! -d "$unit_dir" ]]; then
    nyann::die "--unit does not exist: $unit"
  fi
else
  unit_dir="$target"
fi

# --- build the tool apply command (scoped to the unit dir) -------------------
# nyann supplies NO credentials and NO -var assignments here — the tool reads
# its own ambient auth. -input=false / --non-interactive prevent prompts.
declare -a apply_cmd=()
apply_label=""
apply_cli=""
raw_plan="$(jq -r '.raw_path // ""' <<<"$plan_json")"
case "$tool" in
  terraform|opentofu)
    apply_cli="terraform"; [[ "$tool" == "opentofu" ]] && apply_cli="tofu"
    # Apply the saved plan binary captured by iac-plan (terraform plan -out).
    # The plan binary lives in the raw dir alongside raw_path; derive it.
    plan_bin=""
    if [[ -n "$raw_plan" ]]; then plan_bin="$(dirname "$raw_plan")/plan.tfplan"; fi
    if [[ -n "$plan_bin" && -f "$plan_bin" ]]; then
      apply_cmd=("$apply_cli" apply -input=false "$plan_bin")
      apply_label="$apply_cli apply <plan>"
    else
      apply_cmd=("$apply_cli" apply -input=false -auto-approve)
      apply_label="$apply_cli apply -auto-approve"
    fi
    ;;
  aws-cdk)
    apply_cli="cdk"
    apply_cmd=(cdk deploy --require-approval never)
    apply_label="cdk deploy"
    ;;
  pulumi)
    apply_cli="pulumi"
    apply_cmd=(pulumi up --yes --non-interactive)
    apply_label="pulumi up"
    ;;
  helm)
    apply_cli="helm"
    # The release name is the unit-dir basename. A chart dir / --unit named e.g.
    # `-rf` or `--namespace` would otherwise reach `helm upgrade --install` as a
    # bare flag token and inject helm options (redirecting the install to the
    # wrong cluster/namespace) during THE highest-stakes mutator. Reject a
    # leading-dash name cleanly (matches release-workspace.sh:133), AND pass the
    # name after a `--` separator so helm can never parse it as a flag.
    helm_release="$(basename "$unit_dir")"
    [[ "$helm_release" == -* ]] && nyann::die "helm release name '$helm_release' starts with '-' (helm would parse it as an option); rename the chart dir"
    apply_cmd=(helm upgrade --install -- "$helm_release" .)
    apply_label="helm upgrade --install"
    ;;
  kubernetes)
    apply_cli="kubectl"
    apply_cmd=(kubectl apply -f .)
    apply_label="kubectl apply -f ."
    ;;
  kustomize)
    apply_cli="kubectl"
    apply_cmd=(kubectl apply -k .)
    apply_label="kubectl apply -k ."
    ;;
  ansible)
    apply_cli="ansible-playbook"
    playbook=""
    for cand in site.yml site.yaml playbook.yml playbook.yaml main.yml main.yaml; do
      [[ -f "$unit_dir/$cand" ]] && { playbook="$cand"; break; }
    done
    [[ -n "$playbook" ]] || nyann::die "no playbook found in $unit_dir for apply"
    apply_cmd=(ansible-playbook "$playbook")
    apply_label="ansible-playbook <playbook>"
    ;;
  *) nyann::die "unsupported iac.tool for apply: $tool" ;;
esac

# --- GATE 3: CLI presence (soft-skip, never partial-apply) -------------------
if ! command -v "$apply_cli" >/dev/null 2>&1; then
  msg="$apply_cli CLI not installed — skipping apply (nyann never installs or authenticates tools)"
  nyann::warn "$msg"
  emit "skipped" "$plan_json" "$(jq -n --arg m "$msg" '{message:$m}')"
  exit 0
fi

# --- execute the apply -------------------------------------------------------
# We DO NOT capture/persist the tool's stdout/stderr (it can echo state). It
# streams to the operator's terminal via stderr — redirecting the tool's
# stdout to stderr keeps THIS script's stdout clean for the JSON result (the
# operator still sees all tool output live; nothing is swallowed or stored).
nyann::log "applying $tool ($apply_label) in $unit_dir"
set +e
( cd "$unit_dir" && "${apply_cmd[@]}" ) >&2
apply_exit=$?
set -e

# --- write the IacApplyRecord (audit; NO creds/state) ------------------------
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ts_dir="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
records_root="memory/.nyann/iac-applies"
# Collision suffix if two applies land in the same UTC second.
rec_rel="$records_root/$ts_dir"
suffix=1
while [[ -e "$target/$rec_rel" ]]; do
  rec_rel="$records_root/${ts_dir}-$suffix"
  suffix=$((suffix + 1))
done
record_path=""
if record_dir="$(nyann::safe_mkdir_under_target "$target" "$rec_rel" 2>/dev/null)"; then
  add=$(jq -r '.summary.add // 0' <<<"$plan_json")
  change=$(jq -r '.summary.change // 0' <<<"$plan_json")
  destructive_known=$(jq -r 'if .destructive_known == true then "true" else "false" end' <<<"$plan_json")
  # plan_sha256: hash of the CANONICAL, credential-free IacPlan only.
  plan_sha=""
  if command -v shasum >/dev/null 2>&1; then
    plan_sha=$(jq -Sc . <<<"$plan_json" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    plan_sha=$(jq -Sc . <<<"$plan_json" | sha256sum | awk '{print $1}')
  fi
  confirm_destroy_recorded="false"; $confirm_destroy && confirm_destroy_recorded="true"
  # Record's confirm_destroy reflects whether the flag was required+passed.
  [[ "$guard_verdict" == "not-required" ]] && confirm_destroy_recorded="false"

  record_json=$(jq -n \
    --arg created_at "$created_at" \
    --arg target "$(basename "$target")" \
    --arg tool "$tool" \
    --arg unit "$unit_label" \
    --argjson add "$add" \
    --argjson change "$change" \
    --argjson destroy "$destroy" \
    --argjson destructive "$destructive" \
    --argjson destructive_known "$destructive_known" \
    --argjson confirm_destroy "$confirm_destroy_recorded" \
    --arg guard_verdict "$guard_verdict" \
    --arg apply_label "$apply_label" \
    --argjson exit_code "$apply_exit" \
    '{
      schema_version:1, created_at:$created_at, target:$target,
      tool:$tool, unit:$unit,
      summary:{add:$add, change:$change, destroy:$destroy},
      destructive:$destructive, destructive_known:$destructive_known,
      gates:{apply_flag:true, confirm_destroy:$confirm_destroy, confirmation_guard:$guard_verdict},
      apply:{command:$apply_label, exit_code:$exit_code},
      message:(if $exit_code == 0 then "apply succeeded" else "apply exited \($exit_code)" end)
    }')
  if [[ -n "$plan_sha" ]]; then
    record_json=$(jq --arg s "$plan_sha" '. + {plan_sha256:$s}' <<<"$record_json")
  fi
  # Atomic write (tempfile + mv) so a reader never sees a half-written record.
  tmp_rec="$record_dir/.manifest.json.tmp"
  printf '%s\n' "$record_json" > "$tmp_rec"
  mv "$tmp_rec" "$record_dir/manifest.json"
  record_path="$record_dir/manifest.json"
else
  nyann::warn "could not write IacApplyRecord under $rec_rel — apply already ran; audit record skipped"
fi

extra=$(jq -n \
  --arg rp "$record_path" \
  --argjson ec "$apply_exit" \
  --arg m "$(if (( apply_exit == 0 )); then echo "apply succeeded"; else echo "apply exited $apply_exit"; fi)" \
  '{exit_code:$ec, message:$m} + (if $rp != "" then {record_path:$rp} else {} end)')

emit "applied" "$plan_json" "$extra"
[[ "$apply_exit" == "0" ]] || exit "$apply_exit"
exit 0
