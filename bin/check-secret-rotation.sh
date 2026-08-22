#!/usr/bin/env bash
# check-secret-rotation.sh — rotation REMINDERS for secret-bearing files.
#
# Usage:
#   check-secret-rotation.sh --target <repo> --profile <path>
#
# For each glob in the profile's security.rotation_reminder.files[],
# resolves TRACKED files (git ls-files — an untracked local .env is the
# user's business) and computes age from the last COMMIT touching the file
# (git log -1 %ct — mtime is clone-time noise), flagging files older than
# max_age_days. Emits a RotationReport (schemas/rotation-report.schema.json)
# on stdout.
#
# This is a reminder, not verification: touching `.env.example` does not
# prove the underlying secret rotated, and the wording downstream (doctor's
# SECRET ROTATION section) says "last modified" for exactly that reason.
# Advisory-only by design — consumed as an informational doctor section,
# never an exit-code signal.
#
# Exit codes: 0 whenever a report was produced (findings included); 1 on
# hard errors only. Disabled → an enabled:false report, cheap no-op.
#
# Requires jq.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --profile)   profile_path="${2-}"; shift 2 ;;
    --profile=*) profile_path="${1#--profile=}"; shift ;;
    -h|--help)   sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"

enabled=false
max_age=90
globs='[".env.example"]'
if [[ -n "$profile_path" && -f "$profile_path" ]]; then
  enabled=$(jq -r '.security.rotation_reminder.enabled // false' "$profile_path" 2>/dev/null || echo false)
  ma=$(jq -r '.security.rotation_reminder.max_age_days // empty' "$profile_path" 2>/dev/null || true)
  [[ "$ma" =~ ^[0-9]+$ ]] && max_age="$ma"
  g=$(jq -c '.security.rotation_reminder.files // empty' "$profile_path" 2>/dev/null || true)
  [[ -n "$g" ]] && globs="$g"
fi

if [[ "$enabled" != "true" ]]; then
  jq -n '{enabled: false, max_age_days: null, findings: [], summary: {checked: 0, stale: 0}}'
  exit 0
fi

now_epoch=$(date +%s)
findings='[]'
checked=0

while IFS= read -r glob; do
  [[ -z "$glob" ]] && continue
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    checked=$((checked + 1))
    ct=$(git -C "$target" log -1 --format=%ct -- "$f" 2>/dev/null || true)
    [[ "$ct" =~ ^[0-9]+$ ]] || continue
    age_days=$(( (now_epoch - ct) / 86400 ))
    if (( age_days > max_age )); then
      findings=$(jq --arg f "$f" --argjson a "$age_days" --argjson m "$max_age" \
        '. + [{file: $f, age_days: $a, max_age_days: $m}]' <<<"$findings")
    fi
  done < <(git -C "$target" ls-files -- "$glob" 2>/dev/null || true)
done < <(jq -r '.[]' <<<"$globs" 2>/dev/null || true)

jq -n --argjson f "$findings" --argjson m "$max_age" --argjson c "$checked" \
  '{enabled: true, max_age_days: $m, findings: ($f | sort_by(-.age_days)),
    summary: {checked: $c, stale: ($f | length)}}'
exit 0
