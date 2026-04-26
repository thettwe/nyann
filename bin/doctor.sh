#!/usr/bin/env bash
# doctor.sh — read-only hygiene audit.
#
# Usage: doctor.sh --target <repo> --profile <name> [--json] [--persist]
#
# Wraps bin/retrofit.sh --report-only so hygiene + profile-compliance
# output is always identical between doctor and retrofit. doctor is the
# read-only path: same analysis, never offers remediation, never writes
# to the filesystem.
#
# --persist (off by default) opts the user into recording the computed
# health score to memory/health.json so trend deltas show up on
# subsequent runs. Without --persist, doctor stays strictly read-only.
# Trend display still works against any existing memory/health.json.
#
# Covers hygiene + profile compliance + documentation drift (link check,
# orphans, CLAUDE.md size).
#
# Exit codes (mirror retrofit):
#   0 — clean (no drift)
#   4 — warnings only (misconfigured / non-compliant history)
#   5 — critical (missing files)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

score_tmp=""
trap 'rm -f "${score_tmp:-}"' EXIT

target=""
profile_name=""
json_out=false
persist=false
gh_bin="gh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2:-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --profile)   profile_name="${2:-}"; shift 2 ;;
    --profile=*) profile_name="${1#--profile=}"; shift ;;
    --json)      json_out=true; shift ;;
    --persist)   persist=true; shift ;;
    --gh)        gh_bin="${2:-}"; shift 2 ;;
    --gh=*)      gh_bin="${1#--gh=}"; shift ;;
    -h|--help)   sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_name" ]] || nyann::die "--profile <name> is required"

args=(--target "$target" --profile "$profile_name")
if $json_out; then
  args+=(--json)
else
  args+=(--report-only)
fi

# --- GitHub protection probe (read-only) ------------------------------------
# Runs before retrofit so its result lands in both the JSON path and the
# text path. Soft-skips when gh is missing or unauthenticated; the audit
# emits a ProtectionAudit-shaped skip JSON in that case.
protection_audit_json=$("${_script_dir}/gh-integration.sh" \
  --target "$target" --profile "$profile_name" \
  --gh "$gh_bin" --check 2>/dev/null || echo '{}')
if [[ -z "$protection_audit_json" ]] || \
   [[ "$(jq -r 'type' <<<"$protection_audit_json" 2>/dev/null || echo "")" != "object" ]]; then
  protection_audit_json='{}'
fi
pa_critical=$(jq -r '.summary.critical // 0' <<<"$protection_audit_json")
pa_warn=$(jq -r '.summary.warn // 0' <<<"$protection_audit_json")

# --- Stale-branch probe (read-only) -----------------------------------------
# Pulls profile.branching.stale_after_days (default 90); base branch is
# auto-resolved by the script. No drift contributes to exit code (these
# are housekeeping signals, not safety violations) but counts surface
# in the text + JSON output so the user can decide to run cleanup.
stale_days=$(bash "${_script_dir}/load-profile.sh" "$profile_name" 2>/dev/null \
  | jq -r '.branching.stale_after_days // 90' 2>/dev/null || echo 90)
[[ "$stale_days" =~ ^[0-9]+$ ]] || stale_days=90
stale_branches_json=$("${_script_dir}/check-stale-branches.sh" \
  --target "$target" --days "$stale_days" 2>/dev/null || echo '{}')
if [[ -z "$stale_branches_json" ]] || \
   [[ "$(jq -r 'type' <<<"$stale_branches_json" 2>/dev/null || echo "")" != "object" ]]; then
  stale_branches_json='{}'
fi
sb_merged=$(jq -r '.summary.merged_count // 0' <<<"$stale_branches_json")
sb_stale=$(jq -r '.summary.stale_count // 0' <<<"$stale_branches_json")

# retrofit.sh handles the heavy lifting.
retro_rc=0
if $json_out; then
  # Capture JSON output so we can append health_score
  retro_output=$("${_script_dir}/retrofit.sh" "${args[@]}") || retro_rc=$?

  # Compute health score from the drift report
  score_json=$(printf '%s\n' "$retro_output" | "${_script_dir}/compute-health-score.sh" 2>/dev/null || echo '{"score":0,"breakdown":{}}')

  # Persist score to memory/health.json — opt-in via --persist so the
  # default doctor invocation stays strictly read-only as documented.
  if $persist; then
    score_tmp=$(mktemp -t nyann-score.XXXXXX)
    printf '%s\n' "$score_json" > "$score_tmp"
    "${_script_dir}/persist-health-score.sh" --target "$target" --score "$score_tmp" --profile "$profile_name" >/dev/null 2>&1 || true
    rm -f "$score_tmp"
  fi

  # Add health_score, protection_audit, AND stale_branches to output
  printf '%s\n' "$retro_output" | jq \
    --argjson hs "$score_json" \
    --argjson pa "$protection_audit_json" \
    --argjson sb "$stale_branches_json" \
    '. + { health_score: $hs, protection_audit: $pa, stale_branches: $sb }'
else
  # Capture JSON drift data first for health scoring (suppressed output)
  drift_json=$("${_script_dir}/retrofit.sh" --target "$target" --profile "$profile_name" --json 2>/dev/null || echo '{}')

  # Display human-readable text report
  "${_script_dir}/retrofit.sh" "${args[@]}" || retro_rc=$?

  # Compute health score from the captured JSON
  score_json=$(printf '%s\n' "$drift_json" | "${_script_dir}/compute-health-score.sh" 2>/dev/null || echo '{"score":0,"breakdown":{}}')

  score_val=$(jq -r '.score' <<<"$score_json")
  breakdown=$(jq -r '.breakdown | to_entries | map(select(.value < 0)) | map("  \(.value)  \(.key)") | join("\n")' <<<"$score_json")

  # Read trend from memory/health.json if it exists
  trend_delta=""
  if [[ -f "$target/memory/health.json" ]]; then
    trend_dir=$(jq -r '.trend.direction // "stable"' "$target/memory/health.json")
    trend_d=$(jq -r '.trend.delta // 0' "$target/memory/health.json")
    case "$trend_dir" in
      up)     trend_delta=" (↑${trend_d} from last session)" ;;
      down)   trend_delta=" (↓${trend_d#-} from last session)" ;;
      stable) trend_delta=" (→ stable)" ;;
    esac
  fi

  printf '\nHEALTH SCORE: %s/100%s\n' "$score_val" "$trend_delta"
  if [[ -n "$breakdown" ]]; then
    printf '%s\n' "$breakdown"
  fi

  # Persist score — opt-in via --persist (see header comment).
  if $persist; then
    score_tmp=$(mktemp -t nyann-score.XXXXXX)
    printf '%s\n' "$score_json" > "$score_tmp"
    "${_script_dir}/persist-health-score.sh" --target "$target" --score "$score_tmp" --profile "$profile_name" >/dev/null 2>&1 || true
    rm -f "$score_tmp"
  fi
fi

# --- protection probe → exit code + text-mode display -----------------------
# In text mode, render a compact one-section summary so users see the
# audit alongside drift + health. JSON mode already merged the audit
# above. Either way, fold critical/warn counts into the exit code so
# `doctor; echo $?` still discriminates clean / warn / critical.
if (( pa_critical > 0 )); then
  retro_rc=5
elif (( pa_warn > 0 )) && (( retro_rc < 4 )); then
  retro_rc=4
fi
if ! $json_out; then
  pa_total=$(jq -r '.summary.total_drift // 0' <<<"$protection_audit_json")
  if (( pa_total > 0 )); then
    printf '\nGITHUB PROTECTION: %s drift item(s) (%s critical, %s warn)\n' \
      "$pa_total" "$pa_critical" "$pa_warn"
    jq -r '
      ([.branches[]? | select(.drift | length > 0) |
        "  ✗ branches/" + .name + ": " +
        ((.drift | map(.field) | unique | join(", ")))]
       + (if (.tag_protection.skipped // false) then []
          elif ((.tag_protection.drift // []) | length) > 0 then
            ["  ✗ tags: " + ((.tag_protection.drift | map(.field) | unique | join(", ")))]
          else [] end)
       + (if ((.codeowners_gate.drift // []) | length) > 0 then
            ["  ✗ codeowners: " + ((.codeowners_gate.drift | map(.kind) | unique | join(", ")))]
          else [] end)
       + (if (.security.skipped // false) then []
          elif ((.security.drift // []) | length) > 0 then
            ["  ✗ security: " + ((.security.drift | map(.field) | unique | join(", ")))]
          else [] end)
      ) | .[]
    ' <<<"$protection_audit_json"
  fi
  # Stale-branch summary — informational; doesn't change exit code.
  # Surfaces the action so users can run /nyann:cleanup-branches.
  if (( sb_merged > 0 )) || (( sb_stale > 0 )); then
    printf '\nLOCAL BRANCHES: %s merged-into-base (deletable), %s stale unmerged (>%s days)\n' \
      "$sb_merged" "$sb_stale" "$stale_days"
    if (( sb_merged > 0 )); then
      printf '  ⚠ run /nyann:cleanup-branches to prune the merged set\n'
    fi
  fi
fi

exit "$retro_rc"
