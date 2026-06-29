#!/usr/bin/env bash
# iac-plan/_advisory.sh — shared body for the ADVISORY (text-diff-only) plan
# adapters: helm, kubernetes, kustomize, ansible.
#
# In v1.13.0 these tools produce a human diff with NO reliable structured
# resource-action summary (the spec's defensible cut — helm-diff/kubectl-diff
# need plugins/clusters; ansible --check has no machine-readable destroy count).
# So an advisory adapter:
#   - emits add/change/destroy = 0 (counts are unknown, NOT a safety claim),
#   - sets advisory:true and destructive_known:FALSE,
#   - which makes bin/iac-apply.sh treat the plan as POTENTIALLY DESTRUCTIVE —
#     it demands --confirm-destroy + the confirmation guard before applying.
#     "Unknown" fails safe toward the destructive gate, never away from it.
#
# Each adapter sources this file and calls:
#   _adv_run <cli> <raw-basename> <summary-line> -- <cmd...>
# which soft-skips (exit 3) when <cli> is absent, runs <cmd...> in $unit_dir
# capturing combined output into $raw_dir/<raw-basename>, and on completion
# (any exit code — a diff tool's non-zero "has changes" is fine) prints the
# advisory JSON line and exits 0. A tool that cannot run because of a missing
# cluster/backend still soft-skips: we only emit "planned" when the diff
# command produced output we could capture.

# Shared arg parse for advisory adapters. Sets unit_dir / raw_dir globals.
_adv_parse_args() {
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
  command -v jq >/dev/null 2>&1 || { printf 'jq not installed\n' >&2; exit 2; }
}

# _adv_run <cli> <raw-basename> <summary-line> -- <cmd...>
_adv_run() {
  local cli="$1" raw_basename="$2" summary_line="$3"
  shift 3
  [[ "${1-}" == "--" ]] && shift
  if ! command -v "$cli" >/dev/null 2>&1; then
    printf '%s CLI not installed — skipping advisory diff\n' "$cli" >&2
    exit 3
  fi
  local raw_path="$raw_dir/$raw_basename"
  # Advisory: capture combined output; the diff command's exit code is NOT a
  # failure signal (a diff tool returns non-zero when there IS a diff). We only
  # care that we captured something to show. If the command can't even start
  # (missing cluster/backend), it typically writes an error we still capture —
  # but produces no usable diff, so soft-skip on empty output.
  ( cd "$unit_dir" && "$@" ) >"$raw_path" 2>&1 || true
  if [[ ! -s "$raw_path" ]]; then
    printf '%s produced no diff (no cluster/backend/release?) — skipping\n' "$cli" >&2
    exit 3
  fi
  jq -nc \
    --arg raw "$raw_path" \
    --arg line "$summary_line" \
    '{add:0, change:0, destroy:0,
      destructive_known:false, advisory:true, raw_path:$raw,
      summary_line:$line}'
  exit 0
}
