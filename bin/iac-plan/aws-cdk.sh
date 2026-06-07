#!/usr/bin/env bash
# iac-plan/aws-cdk.sh — AWS CDK plan adapter (structured via `cdk diff` parse).
#
# Contract: see bin/iac-plan/terraform.sh header. Same stdout-JSON / exit-3
# soft-skip protocol.
#
# CDK has no JSON plan format, but `cdk diff` emits a stable, parseable
# resource-change prefix per line in its "Resources" section:
#   [+] ...   resource to be ADDED
#   [-] ...   resource to be REMOVED   (destructive)
#   [~] ...   resource to be MODIFIED
# We count those prefixes. A `[-]` ⇒ destructive. Because this is a deterministic
# parse of a structured-enough diff (not a freeform text diff like helm/k8s),
# the spec classes CDK as FIRST-CLASS: destructive_known is TRUE.
#
# `cdk diff` compares the synthesized template against the DEPLOYED stack, so it
# reaches AWS and needs bootstrapped credentials — nyann never supplies them;
# CDK uses the operator's ambient AWS auth. When cdk is absent OR the diff can't
# reach AWS (no creds/bootstrap), we soft-skip (exit 3), never partial-anything.
set -o errexit
set -o nounset
set -o pipefail

unit_dir=""
raw_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit-dir)   unit_dir="${2-}"; shift 2 ;;
    --unit-dir=*) unit_dir="${1#--unit-dir=}"; shift ;;
    --raw-dir)    raw_dir="${2-}"; shift 2 ;;
    --raw-dir=*)  raw_dir="${1#--raw-dir=}"; shift ;;
    --cli|--cli=*) shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -d "$unit_dir" ]] || { printf 'unit dir not found: %s\n' "$unit_dir" >&2; exit 2; }
[[ -d "$raw_dir"  ]] || { printf 'raw dir not found: %s\n'  "$raw_dir"  >&2; exit 2; }

if ! command -v cdk >/dev/null 2>&1; then
  printf 'cdk CLI not installed — skipping diff\n' >&2
  exit 3
fi
command -v jq >/dev/null 2>&1 || { printf 'jq not installed\n' >&2; exit 2; }

diff_txt="$raw_dir/cdk-diff.txt"

# `cdk diff` exits 0 (no diff) or 1 (has diff); >1 is an error (e.g. no creds).
# Capture output regardless; treat exit >1 as a soft-skip (likely AWS access).
set +e
( cd "$unit_dir" && cdk diff ) >"$diff_txt" 2>&1
rc=$?
set -e
if (( rc > 1 )); then
  reason="$(tr -d '\r' < "$diff_txt" | grep -iE 'credential|not bootstrapped|unable to resolve|access denied|expired|no stacks' | head -1 || true)"
  [[ -n "$reason" ]] || reason="cdk diff could not reach AWS (no credentials/bootstrap) — skipping"
  printf '%s\n' "$reason" >&2
  exit 3
fi

# Count the resource-change prefixes. Restrict to the resource-change markers
# CDK uses; lines outside the Resources section don't carry these prefixes.
add=$(grep -cE '^\s*\[\+\]' "$diff_txt" 2>/dev/null || true)
change=$(grep -cE '^\s*\[~\]' "$diff_txt" 2>/dev/null || true)
destroy=$(grep -cE '^\s*\[-\]' "$diff_txt" 2>/dev/null || true)
add=${add//[^0-9]/}; change=${change//[^0-9]/}; destroy=${destroy//[^0-9]/}
add=${add:-0}; change=${change:-0}; destroy=${destroy:-0}

jq -nc \
  --argjson add "$add" \
  --argjson change "$change" \
  --argjson destroy "$destroy" \
  --arg raw "$diff_txt" \
  '{add:$add, change:$change, destroy:$destroy,
    destructive_known:true, advisory:false, raw_path:$raw,
    summary_line:("\($add) to add, \($change) to modify, \($destroy) to remove")}'
exit 0
