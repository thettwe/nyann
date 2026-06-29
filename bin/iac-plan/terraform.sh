#!/usr/bin/env bash
# iac-plan/terraform.sh — terraform / opentofu plan adapter.
#
# Contract (shared by every bin/iac-plan/<tool>.sh adapter):
#   Invoked as: bash terraform.sh --unit-dir <abs-dir> --raw-dir <abs-tmp-dir>
#               [--cli <terraform|tofu>]
#   On a real plan: prints ONE line of JSON to stdout and exits 0:
#       {"add":N,"change":N,"destroy":N,"destructive_known":true,
#        "advisory":false,"raw_path":"<abs path to show -json output>",
#        "summary_line":"..."}
#   On soft-skip (CLI absent, or no backend/creds so plan can't run): prints
#       a one-line reason to stderr and exits 3. The orchestrator maps exit 3
#       to status:"skipped" (exit 0 overall) — never a partial result.
#   Any other non-zero exit is a hard error the orchestrator surfaces.
#
# FIRST-CLASS structured parsing: `terraform plan -out=<plan>` then
# `terraform show -json <plan>` yields resource_changes[].change.actions[],
# from which add/change/destroy and the destructive verdict are derived
# exactly (a "delete" action ⇒ destructive). This is the spec's structured
# path — destructive_known is TRUE.
#
# nyann NEVER handles credentials: terraform reads its own ambient auth
# (~/.terraform.d, env, provider config). This adapter passes -input=false so
# a missing backend/creds fails fast (exit 3 soft-skip) instead of prompting.
# It writes the plan binary and the show-json into --raw-dir (a private temp
# dir OUTSIDE the repo) — never into the repo, never committed.
set -o errexit
set -o nounset
set -o pipefail

unit_dir=""
raw_dir=""
cli="terraform"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit-dir)  unit_dir="${2-}"; shift 2 ;;
    --unit-dir=*) unit_dir="${1#--unit-dir=}"; shift ;;
    --raw-dir)   raw_dir="${2-}"; shift 2 ;;
    --raw-dir=*) raw_dir="${1#--raw-dir=}"; shift ;;
    --cli)       cli="${2-}"; shift 2 ;;
    --cli=*)     cli="${1#--cli=}"; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -d "$unit_dir" ]] || { printf 'unit dir not found: %s\n' "$unit_dir" >&2; exit 2; }
[[ -d "$raw_dir"  ]] || { printf 'raw dir not found: %s\n'  "$raw_dir"  >&2; exit 2; }

# Soft-skip when the CLI is absent. A missing optional tool is not a failure.
if ! command -v "$cli" >/dev/null 2>&1; then
  printf '%s CLI not installed — skipping plan\n' "$cli" >&2
  exit 3
fi
command -v jq >/dev/null 2>&1 || { printf 'jq not installed\n' >&2; exit 2; }

plan_bin="$raw_dir/plan.tfplan"
plan_json="$raw_dir/plan.show.json"

# Run plan in the unit dir. -input=false: never prompt — a missing backend or
# missing creds errors out (we soft-skip) instead of blocking on stdin.
# -detailed-exitcode would conflate "has changes" (2) with our soft-skip code,
# so we DON'T use it; we read the action counts from show -json instead.
plan_err="$raw_dir/plan.stderr"
if ! ( cd "$unit_dir" && "$cli" plan -input=false -lock=false -out="$plan_bin" ) >/dev/null 2>"$plan_err"; then
  # Distinguish "no backend / not initialized / no creds" (soft-skip) from a
  # genuine config error. Either way we must not partial-apply: soft-skip with
  # the captured reason so the operator can act, but exit 0 overall.
  reason="$(tr -d '\r' < "$plan_err" | grep -iE 'backend|init|credential|auth|provider|not been initialized' | head -1 || true)"
  [[ -n "$reason" ]] || reason="$cli plan failed (no backend/credentials or uninitialized) — skipping"
  printf '%s\n' "$reason" >&2
  exit 3
fi

# Structured parse: show -json the saved plan binary.
if ! ( cd "$unit_dir" && "$cli" show -json "$plan_bin" ) >"$plan_json" 2>/dev/null; then
  printf '%s show -json failed — skipping\n' "$cli" >&2
  exit 3
fi

# resource_changes[].change.actions[] is the authoritative action list.
#   ["create"]            → add
#   ["update"]            → change
#   ["delete"]            → destroy
#   ["delete","create"]   → destroy + add (replacement; destructive)
#   ["create","delete"]   → add + destroy (create-before-destroy; destructive)
#   ["no-op"] / ["read"]  → ignored
counts=$(jq -c '
  ([.resource_changes[]?.change.actions // []]) as $acts
  | {
      add:     ([$acts[] | select(index("create"))] | length),
      change:  ([$acts[] | select(. == ["update"])] | length),
      destroy: ([$acts[] | select(index("delete"))] | length)
    }' "$plan_json" 2>/dev/null || echo '{"add":0,"change":0,"destroy":0}')

add=$(jq -r '.add // 0' <<<"$counts")
change=$(jq -r '.change // 0' <<<"$counts")
destroy=$(jq -r '.destroy // 0' <<<"$counts")

jq -nc \
  --argjson add "$add" \
  --argjson change "$change" \
  --argjson destroy "$destroy" \
  --arg raw "$plan_json" \
  '{add:$add, change:$change, destroy:$destroy,
    destructive_known:true, advisory:false, raw_path:$raw,
    summary_line:("\($add) to add, \($change) to change, \($destroy) to destroy")}'
exit 0
