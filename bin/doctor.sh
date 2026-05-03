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
tmp_profile=""
load_err=""
trap 'rm -f "${score_tmp:-}" "${tmp_profile:-}" "${load_err:-}"' EXIT

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

# --- Load profile ONCE -------------------------------------------------------
# Previously load-profile.sh ran separately to extract stale_days, then
# retrofit.sh called it again internally. Now we load once and pass the
# resolved profile to compute-drift.sh directly.
tmp_profile=$(mktemp -t nyann-doctor-profile.XXXXXX)
load_err=$(mktemp -t nyann-doctor-load.XXXXXX)
"${_script_dir}/load-profile.sh" "$profile_name" > "$tmp_profile" 2>"$load_err" \
  || { cat "$load_err" >&2; nyann::die "failed to load profile: $profile_name"; }

stale_days=$(jq -r '.branching.stale_after_days // 90' "$tmp_profile" 2>/dev/null || echo 90)
[[ "$stale_days" =~ ^[0-9]+$ ]] || stale_days=90

# --- GitHub protection probe (read-only) ------------------------------------
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
stale_branches_json=$("${_script_dir}/check-stale-branches.sh" \
  --target "$target" --days "$stale_days" 2>/dev/null || echo '{}')
if [[ -z "$stale_branches_json" ]] || \
   [[ "$(jq -r 'type' <<<"$stale_branches_json" 2>/dev/null || echo "")" != "object" ]]; then
  stale_branches_json='{}'
fi
sb_merged=$(jq -r '.summary.merged_count // 0' <<<"$stale_branches_json")
sb_stale=$(jq -r '.summary.stale_count // 0' <<<"$stale_branches_json")

# --- Compute drift ONCE -------------------------------------------------------
# Previously text mode ran retrofit.sh twice (once --json, once --report-only).
# Now compute-drift.sh runs once; JSON mode wraps via retrofit.sh, text mode
# renders directly from the captured JSON.
retro_rc=0

if $json_out; then
  retro_output=$("${_script_dir}/retrofit.sh" --target "$target" --profile "$profile_name" --json) || retro_rc=$?
  score_json=$(printf '%s\n' "$retro_output" | "${_script_dir}/compute-health-score.sh" 2>/dev/null || echo '{"score":0,"breakdown":{}}')

  if $persist; then
    score_tmp=$(mktemp -t nyann-score.XXXXXX)
    printf '%s\n' "$score_json" > "$score_tmp"
    "${_script_dir}/persist-health-score.sh" --target "$target" --score "$score_tmp" --profile "$profile_name" >/dev/null 2>&1 || true
    rm -f "$score_tmp"
  fi

  printf '%s\n' "$retro_output" | jq \
    --argjson hs "$score_json" \
    --argjson pa "$protection_audit_json" \
    --argjson sb "$stale_branches_json" \
    '. + { health_score: $hs, protection_audit: $pa, stale_branches: $sb }'
else
  # Single compute-drift call replaces two retrofit.sh calls.
  report=$("${_script_dir}/compute-drift.sh" --target "$target" --profile "$tmp_profile") \
    || retro_rc=$?

  # Parse summary counters once. IFS=$'\t' so empty middle fields don't
  # shift later variables under default IFS (which collapses tab runs).
  IFS=$'\t' read -r n_missing n_mis n_off n_broken n_orphans n_stale n_subsys_errs claude_md_status < <(
    jq -r '[
      (.summary.missing // 0),
      (.summary.misconfigured // 0),
      (.summary.non_compliant_commits // 0),
      (.summary.broken_links // 0),
      (.summary.orphans // 0),
      (.summary.stale_docs // 0),
      (.summary.subsystem_errors // 0),
      (.summary.claude_md_status // "ok")
    ] | @tsv' <<<"$report"
  )

  # Render text report (mirrors retrofit.sh render_report).
  {
    printf '\nDrift vs. profile %q (target: %s)\n\n' "$profile_name" "$target"
    printf 'MISSING:\n'
    if [[ "$n_missing" == "0" ]]; then
      printf '  (none)\n'
    else
      jq -r '.missing[] | "  ✗ " + .path + ( if .detail then "   # " + .detail else "" end )' <<<"$report"
    fi
    printf '\nMISCONFIGURED:\n'
    if [[ "$n_mis" == "0" ]]; then
      printf '  (none)\n'
    else
      jq -r '.misconfigured[] |
        "  ⚠ " + .path + " — " + .reason +
        ( if .missing_entries then " (missing: " + (.missing_entries | join(", ")) + ")" else "" end )' <<<"$report"
    fi
    printf '\nNON-COMPLIANT HISTORY (last %s commits):\n' "$(jq -r '.non_compliant_history.checked' <<<"$report")"
    if [[ "$n_off" == "0" ]]; then
      printf '  (none — informational only; history rewrites are out of scope)\n'
    else
      jq -r '.non_compliant_history.offenders[] | "  ⚠ " + .sha + "  " + .subject' <<<"$report"
      printf '  (%s commit(s) above — informational only; history rewrites are out of scope)\n' "$n_off"
    fi

    printf '\nDOCUMENTATION:\n'
    case "$claude_md_status" in
      ok)     printf '  ✓ CLAUDE.md %s B (under %s B budget)\n' \
                "$(jq -r '.documentation.claude_md.bytes' <<<"$report")" \
                "$(jq -r '.documentation.claude_md.budget_bytes' <<<"$report")" ;;
      warn)   printf '  ⚠ CLAUDE.md %s B (> %s B soft budget)\n' \
                "$(jq -r '.documentation.claude_md.bytes' <<<"$report")" \
                "$(jq -r '.documentation.claude_md.budget_bytes' <<<"$report")" ;;
      error)  printf '  ✗ CLAUDE.md %s B (> %s B hard cap — extract)\n' \
                "$(jq -r '.documentation.claude_md.bytes' <<<"$report")" \
                "$(jq -r '.documentation.claude_md.hard_cap_bytes' <<<"$report")" ;;
      absent) printf '  ⚠ CLAUDE.md missing (no router file present)\n' ;;
    esac

    checked_links=$(jq -r '.documentation.links.checked' <<<"$report")
    if [[ "$n_broken" == "0" ]]; then
      printf '  ✓ %s internal link(s) resolve\n' "$checked_links"
    else
      printf '  ✗ %s broken internal link(s):\n' "$n_broken"
      jq -r '.documentation.links.broken[] | "      - " + .source + " → " + .link' <<<"$report"
    fi

    n_mcp=$(jq '.documentation.links.needs_mcp_verify | length' <<<"$report")
    if [[ "$n_mcp" != "0" ]]; then
      printf '  ⚠ %s MCP link(s) need connector verification (skill-layer)\n' "$n_mcp"
    fi

    if [[ "$n_orphans" == "0" ]]; then
      printf '  ✓ 0 orphans in docs/ + memory/\n'
    else
      printf '  ⚠ %s orphan(s) in docs/ + memory/:\n' "$n_orphans"
      jq -r '.documentation.orphans.orphans[] | "      - " + .path + "  (" + (.last_modified_days_ago|tostring) + " days)"' <<<"$report"
    fi

    staleness_enabled=$(jq -r '.documentation.staleness.enabled' <<<"$report")
    if [[ "$staleness_enabled" == "true" ]]; then
      threshold=$(jq -r '.documentation.staleness.threshold_days' <<<"$report")
      if [[ "$n_stale" == "0" ]]; then
        printf '  ✓ 0 docs past staleness threshold (%s days)\n' "$threshold"
      else
        printf '  ⚠ %s doc(s) past staleness threshold (%s days):\n' "$n_stale" "$threshold"
        jq -r '.documentation.staleness.stale[] | "      - " + .path + "  (" + (.last_modified_days_ago|tostring) + " days)"' <<<"$report"
      fi
    fi

    if (( n_subsys_errs > 0 )); then
      printf '  ⚠ %s doc-check subsystem(s) failed to execute; results may be incomplete:\n' "$n_subsys_errs"
      jq -r '.documentation.subsystem_errors[] | "      - " + .subsystem + ": " + .error' <<<"$report"
    fi

    printf '\n'
  } >&2

  # Determine exit code from drift.
  has_critical=false
  has_warn=false
  (( n_missing > 0 )) && has_critical=true
  (( n_broken > 0 )) && has_critical=true
  [[ "$claude_md_status" == "error" ]] && has_critical=true
  (( n_mis > 0 )) && has_warn=true
  (( n_off > 0 )) && has_warn=true
  (( n_orphans > 0 )) && has_warn=true
  (( n_stale > 0 )) && has_warn=true
  (( n_subsys_errs > 0 )) && has_warn=true
  [[ "$claude_md_status" == "warn" || "$claude_md_status" == "absent" ]] && has_warn=true

  if $has_critical; then retro_rc=5
  elif $has_warn; then retro_rc=4
  fi

  # Compute health score from the same drift JSON.
  score_json=$(printf '%s\n' "$report" | "${_script_dir}/compute-health-score.sh" 2>/dev/null || echo '{"score":0,"breakdown":{}}')

  score_val=$(jq -r '.score' <<<"$score_json")
  breakdown=$(jq -r '.breakdown | to_entries | map(select(.value < 0)) | map("  \(.value)  \(.key)") | join("\n")' <<<"$score_json")

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
