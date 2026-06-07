#!/usr/bin/env bash
# iac-plan/pulumi.sh — Pulumi plan adapter (FIRST-CLASS structured parsing).
#
# Contract: see bin/iac-plan/terraform.sh header. Same stdout-JSON / exit-3
# soft-skip protocol.
#
# `pulumi preview --json` emits a stream/object whose `.steps[].op` carries the
# operation per resource: create | update | replace | delete | same | read.
# Newer Pulumi also emits `.changeSummary` with op→count. We prefer
# changeSummary when present, else fold .steps[].op. A `delete` or `replace`
# op ⇒ destructive (replace tears down then recreates). destructive_known TRUE.
#
# nyann NEVER handles credentials. `pulumi preview` needs a configured backend
# + login; --non-interactive prevents a prompt from hanging. When the backend
# /login/creds are absent the command fails → we soft-skip (exit 3), never
# partial-anything. Output JSON is written to --raw-dir (outside the repo).
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
    --cli|--cli=*) shift ;;  # pulumi has a single CLI name; accept+ignore for symmetry
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -d "$unit_dir" ]] || { printf 'unit dir not found: %s\n' "$unit_dir" >&2; exit 2; }
[[ -d "$raw_dir"  ]] || { printf 'raw dir not found: %s\n'  "$raw_dir"  >&2; exit 2; }

if ! command -v pulumi >/dev/null 2>&1; then
  printf 'pulumi CLI not installed — skipping preview\n' >&2
  exit 3
fi
command -v jq >/dev/null 2>&1 || { printf 'jq not installed\n' >&2; exit 2; }

preview_json="$raw_dir/preview.json"
preview_err="$raw_dir/preview.stderr"

if ! ( cd "$unit_dir" && pulumi preview --json --non-interactive ) >"$preview_json" 2>"$preview_err"; then
  reason="$(tr -d '\r' < "$preview_err" | grep -iE 'backend|login|credential|auth|no stack|not logged' | head -1 || true)"
  [[ -n "$reason" ]] || reason="pulumi preview failed (no backend/login/credentials) — skipping"
  printf '%s\n' "$reason" >&2
  exit 3
fi

# Prefer changeSummary; fall back to folding steps[].op. `same`/`read` ignored.
counts=$(jq -c '
  (.changeSummary // {}) as $cs
  | if ($cs | length) > 0 then
      {
        add:     (($cs.create // 0)),
        change:  (($cs.update // 0)),
        destroy: (($cs.delete // 0) + ($cs.replace // 0))
      }
    else
      ([.steps[]?.op] // []) as $ops
      | {
          add:     ([$ops[] | select(. == "create")] | length),
          change:  ([$ops[] | select(. == "update")] | length),
          destroy: ([$ops[] | select(. == "delete" or . == "replace")] | length)
        }
    end' "$preview_json" 2>/dev/null || echo '{"add":0,"change":0,"destroy":0}')

add=$(jq -r '.add // 0' <<<"$counts")
change=$(jq -r '.change // 0' <<<"$counts")
destroy=$(jq -r '.destroy // 0' <<<"$counts")

jq -nc \
  --argjson add "$add" \
  --argjson change "$change" \
  --argjson destroy "$destroy" \
  --arg raw "$preview_json" \
  '{add:$add, change:$change, destroy:$destroy,
    destructive_known:true, advisory:false, raw_path:$raw,
    summary_line:("\($add) to create, \($change) to update, \($destroy) to delete/replace")}'
exit 0
