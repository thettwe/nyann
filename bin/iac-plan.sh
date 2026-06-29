#!/usr/bin/env bash
# iac-plan.sh — tool-agnostic IaC plan/preview orchestrator (I9).
#
# Usage:
#   iac-plan.sh [--target <dir>] [--unit <repo-rel-path>]
#
# Detects the repo's iac.tool (via bin/detect-stack.sh), dispatches to the
# per-tool adapter under bin/iac-plan/<tool>.sh, captures machine-readable
# output where available, and emits a normalized IacPlan JSON on stdout:
#   { schema_version, status, tool, unit, summary:{add,change,destroy},
#     destructive, destructive_known, raw_path?, message }
#
# READ-ONLY. iac-plan NEVER mutates infrastructure — it only previews. It is
# the gated input to bin/iac-apply.sh.
#
# Structured (first-class) tools: terraform, opentofu, aws-cdk, pulumi — the
# adapter parses a machine-readable plan and reports destructive_known:true.
# Advisory tools: helm, kubernetes, kustomize, ansible — text diff only;
# summary counts 0 and destructive_known:false (apply treats as potentially
# destructive). This is the spec's defensible v1.13.0 cut.
#
# Safety:
#   - Detection NEVER auto-runs a cloud CLI behind the user's back. detect-stack
#     is pure (filesystem only). The cloud CLI runs ONLY inside the adapter,
#     which the operator invoked by running this plan command explicitly.
#   - Soft-skip (status:"skipped", exit 0) when the tool CLI or its backend/
#     credentials are absent — never a partial result.
#   - nyann NEVER handles credentials. Adapters shell out to the user's already-
#     authenticated CLI; this script reads/stores/logs/passes no secrets. The
#     emitted IacPlan carries no raw plan contents — only a path to the raw
#     output written OUTSIDE the repo (never committed).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
unit=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --unit)     unit="${2-}"; shift 2 ;;
    --unit=*)   unit="${1#--unit=}"; shift ;;
    -h|--help)  sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
target="$(cd "$target" && pwd -P)"

# --- normalized emitters -----------------------------------------------------

emit_skipped() {
  # emit_skipped <tool> <unit> <message>
  jq -n --arg tool "$1" --arg unit "$2" --arg msg "$3" '{
    schema_version:1, status:"skipped", tool:$tool, unit:$unit,
    summary:{add:0,change:0,destroy:0},
    destructive:false, destructive_known:false, message:$msg
  }'
  exit 0
}

emit_refused() {
  # emit_refused <tool> <unit> <message>
  jq -n --arg tool "$1" --arg unit "$2" --arg msg "$3" '{
    schema_version:1, status:"refused", tool:$tool, unit:$unit,
    summary:{add:0,change:0,destroy:0},
    destructive:false, destructive_known:false, message:$msg
  }'
  exit 1
}

# --- detect the tool ---------------------------------------------------------
# Pure filesystem detection — does NOT run any cloud CLI. Override hook for
# tests: NYANN_IAC_TOOL short-circuits detection with a known tool.
if [[ -n "${NYANN_IAC_TOOL:-}" ]]; then
  tool="$NYANN_IAC_TOOL"
else
  descriptor="$(bash "${_script_dir}/detect-stack.sh" --path "$target" 2>/dev/null || echo '{}')"
  tool="$(jq -r '.iac.tool // ""' <<<"$descriptor" 2>/dev/null || echo "")"
fi

if [[ -z "$tool" ]]; then
  emit_skipped "" "${unit:-.}" "no IaC tool detected in $target — nothing to plan"
fi

# --- resolve the unit dir ----------------------------------------------------
# --unit is a repo-relative path. Resolve it under target with the shared
# path-traversal guard so a crafted --unit can't escape the repo. Without
# --unit, the unit is the target root.
unit_label="${unit:-.}"
if [[ -n "$unit" ]]; then
  if ! unit_dir="$(nyann::path_under_target "$target" "$target/$unit" 2>/dev/null)"; then
    emit_refused "$tool" "$unit_label" "--unit escapes target directory: $unit"
  fi
  # The documented "plan a specific discovered stack" workflow hands
  # iac.units[].path to --unit, and for CDK/Pulumi that path is a stack
  # DESCRIPTOR FILE (cdk.json / Pulumi.yaml / a per-stack file), not a dir. The
  # CDK/Pulumi adapters cd to the app root anyway, so when --unit resolves to a
  # file we use its containing directory as the working dir (the traversal guard
  # above already ran on the resolved path, so the parent dir is in-bounds too).
  if [[ -f "$unit_dir" ]]; then
    unit_dir="$(dirname "$unit_dir")"
  elif [[ ! -d "$unit_dir" ]]; then
    emit_refused "$tool" "$unit_label" "--unit does not exist: $unit"
  fi
else
  unit_dir="$target"
fi

# --- map tool → adapter ------------------------------------------------------
adapter=""
cli_arg=()
case "$tool" in
  terraform)  adapter="terraform.sh"; cli_arg=(--cli terraform) ;;
  opentofu)   adapter="terraform.sh"; cli_arg=(--cli tofu) ;;
  aws-cdk)    adapter="aws-cdk.sh" ;;
  pulumi)     adapter="pulumi.sh" ;;
  helm)       adapter="helm.sh" ;;
  kubernetes) adapter="kubernetes.sh" ;;
  kustomize)  adapter="kustomize.sh" ;;
  ansible)    adapter="ansible.sh" ;;
  # Unknown tool: the raw $tool string is NOT in the schema's tool enum
  # (terraform|opentofu|aws-cdk|pulumi|kubernetes|kustomize|helm|ansible|""),
  # so emit tool:"" to keep the refused IacPlan schema-valid. The message still
  # carries the raw name for the operator. Valid-tool refusals below (path
  # traversal, missing adapter, adapter failure) keep their real $tool.
  *) emit_refused "" "$unit_label" "unsupported iac.tool: $tool" ;;
esac

adapter_path="${_script_dir}/iac-plan/${adapter}"
[[ -f "$adapter_path" ]] || emit_refused "$tool" "$unit_label" "adapter not found: $adapter"

# --- raw output dir (OUTSIDE the repo — never committed) ---------------------
raw_dir="$(mktemp -d -t nyann-iac-plan.XXXXXX)"
# NOTE: deliberately NOT trapped for removal — raw_path is referenced by the
# emitted IacPlan and read by iac-apply (terraform apply <plan>). The caller /
# OS tmp reaper owns cleanup. The dir lives under $TMPDIR, never in the repo.

# --- dispatch ----------------------------------------------------------------
# The adapter prints one JSON line on success (exit 0), soft-skips with exit 3
# (CLI/backend absent), or hard-errors with another non-zero code. We capture
# stdout and stderr separately so a soft-skip reason can be surfaced.
adapter_out="$raw_dir/adapter.stdout"
adapter_err="$raw_dir/adapter.stderr"
set +e
# ${cli_arg[@]+...} guards the empty-array expansion under `set -u` on bash 3.2
# (only terraform/opentofu populate cli_arg; the other adapters take no --cli).
bash "$adapter_path" --unit-dir "$unit_dir" --raw-dir "$raw_dir" ${cli_arg[@]+"${cli_arg[@]}"} \
  >"$adapter_out" 2>"$adapter_err"
rc=$?
set -e

if (( rc == 3 )); then
  reason="$(tr -d '\r' < "$adapter_err" | grep -v '^$' | tail -1 || true)"
  [[ -n "$reason" ]] || reason="$tool CLI or backend/credentials absent — skipping plan"
  emit_skipped "$tool" "$unit_label" "$reason"
fi
if (( rc != 0 )); then
  reason="$(tr -d '\r' < "$adapter_err" | grep -v '^$' | tail -1 || true)"
  [[ -n "$reason" ]] || reason="$tool plan adapter failed (exit $rc)"
  emit_refused "$tool" "$unit_label" "$reason"
fi

raw_json="$(cat "$adapter_out")"
if [[ "$(jq -r 'type' <<<"$raw_json" 2>/dev/null || echo "")" != "object" ]]; then
  emit_refused "$tool" "$unit_label" "$tool adapter emitted malformed output"
fi

add=$(jq -r '.add // 0' <<<"$raw_json")
change=$(jq -r '.change // 0' <<<"$raw_json")
destroy=$(jq -r '.destroy // 0' <<<"$raw_json")
destructive_known=$(jq -r 'if .destructive_known == true then "true" else "false" end' <<<"$raw_json")
raw_path=$(jq -r '.raw_path // ""' <<<"$raw_json")
summary_line=$(jq -r '.summary_line // ""' <<<"$raw_json")

# Destructive verdict:
#   - structured tool (destructive_known:true): destructive ⇔ destroy > 0.
#   - advisory tool (destructive_known:false): destructive is conservatively
#     TRUE — we cannot prove safety from a text diff, so the apply gate must
#     demand --confirm-destroy. "Unknown" fails safe toward the gate.
if [[ "$destructive_known" == "true" ]]; then
  if (( destroy > 0 )); then destructive="true"; else destructive="false"; fi
else
  destructive="true"
fi

jq -n \
  --arg tool "$tool" \
  --arg unit "$unit_label" \
  --argjson add "$add" \
  --argjson change "$change" \
  --argjson destroy "$destroy" \
  --argjson destructive "$destructive" \
  --argjson destructive_known "$destructive_known" \
  --arg raw_path "$raw_path" \
  --arg line "$summary_line" \
  '{
    schema_version:1, status:"planned", tool:$tool, unit:$unit,
    summary:{add:$add, change:$change, destroy:$destroy},
    destructive:$destructive, destructive_known:$destructive_known
  }
  + (if $raw_path != "" then {raw_path:$raw_path} else {} end)
  + (if $line != "" then {message:$line} else {} end)'
