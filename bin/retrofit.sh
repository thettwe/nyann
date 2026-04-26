#!/usr/bin/env bash
# retrofit.sh — compute drift for an existing repo and offer remediation.
#
# Usage:
#   retrofit.sh --target <repo> --profile <name>
#               [--report-only]   # skip the remediation prompt (doctor mode)
#               [--json]          # emit DriftReport JSON on stdout (for wraps)
#
# Behavior:
#   1. Call bin/compute-drift.sh for the DriftReport.
#   2. Render the three sections (MISSING / MISCONFIGURED / NON-COMPLIANT
#      HISTORY).
#   3. If drift is found AND --report-only isn't set, ask the user whether
#      to build a remediation plan via bootstrap.sh → preview → execute.
#
# --json makes the script print the DriftReport to stdout without the
# human-readable text and without the remediation prompt. Used by doctor.sh.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_name=""
report_only=false
json_out=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="${2:-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --profile)     profile_name="${2:-}"; shift 2 ;;
    --profile=*)   profile_name="${1#--profile=}"; shift ;;
    --report-only) report_only=true; shift ;;
    --json)        json_out=true; report_only=true; shift ;;
    -h|--help)     sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_name" ]] || nyann::die "--profile <name> is required"
target="$(cd "$target" && pwd)"

# Resolve profile via load-profile.sh so user overrides work.
# Cover both temp files in one EXIT trap so a non-zero exit from
# compute-drift under `set -e` doesn't leak the profile JSON into /tmp.
tmp_profile=$(mktemp -t nyann-retrofit-profile.XXXXXX)
load_err=$(mktemp -t nyann-retrofit-load.XXXXXX)
trap 'rm -f "$load_err" "$tmp_profile"' EXIT
"${_script_dir}/load-profile.sh" "$profile_name" > "$tmp_profile" 2>"$load_err" \
  || { cat "$load_err" >&2; exit 1; }

report=$("${_script_dir}/compute-drift.sh" --target "$target" --profile "$tmp_profile")

n_missing=$(jq '.summary.missing' <<<"$report")
n_mis=$(jq '.summary.misconfigured' <<<"$report")
n_off=$(jq '.summary.non_compliant_commits' <<<"$report")
n_broken=$(jq '.summary.broken_links' <<<"$report")
n_orphans=$(jq '.summary.orphans' <<<"$report")
n_stale=$(jq '.summary.stale_docs' <<<"$report")
# Surface subsystem failures rather than silently substituting
# clean-looking fallback JSON. Zero when the field is absent (older
# reports / unaffected runs).
n_subsys_errs=$(jq '.summary.subsystem_errors // 0' <<<"$report")
claude_md_status=$(jq -r '.summary.claude_md_status' <<<"$report")

render_report() {
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
    # CLAUDE.md size budget
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

    # Internal link check
    checked_links=$(jq -r '.documentation.links.checked' <<<"$report")
    if [[ "$n_broken" == "0" ]]; then
      printf '  ✓ %s internal link(s) resolve\n' "$checked_links"
    else
      printf '  ✗ %s broken internal link(s):\n' "$n_broken"
      jq -r '.documentation.links.broken[] | "      - " + .source + " → " + .link' <<<"$report"
    fi

    # MCP links flagged as needing verification (skill-side)
    n_mcp=$(jq '.documentation.links.needs_mcp_verify | length' <<<"$report")
    if [[ "$n_mcp" != "0" ]]; then
      printf '  ⚠ %s MCP link(s) need connector verification (skill-layer)\n' "$n_mcp"
    fi

    # Orphans
    if [[ "$n_orphans" == "0" ]]; then
      printf '  ✓ 0 orphans in docs/ + memory/\n'
    else
      printf '  ⚠ %s orphan(s) in docs/ + memory/:\n' "$n_orphans"
      jq -r '.documentation.orphans.orphans[] | "      - " + .path + "  (" + (.last_modified_days_ago|tostring) + " days)"' <<<"$report"
    fi

    # Staleness (opt-in per profile)
    staleness_enabled=$(jq -r '.documentation.staleness.enabled' <<<"$report")
    if [[ "$staleness_enabled" == "true" ]]; then
      n_stale=$(jq '.documentation.staleness.stale | length' <<<"$report")
      threshold=$(jq -r '.documentation.staleness.threshold_days' <<<"$report")
      if [[ "$n_stale" == "0" ]]; then
        printf '  ✓ 0 docs past staleness threshold (%s days)\n' "$threshold"
      else
        printf '  ⚠ %s doc(s) past staleness threshold (%s days):\n' "$n_stale" "$threshold"
        jq -r '.documentation.staleness.stale[] | "      - " + .path + "  (" + (.last_modified_days_ago|tostring) + " days)"' <<<"$report"
      fi
    fi

    # Subsystem-execution failures must be surfaced. A silent
    # substitution here used to mask broken links, orphans, and
    # staleness problems as clean state.
    if (( n_subsys_errs > 0 )); then
      printf '  ⚠ %s doc-check subsystem(s) failed to execute; results may be incomplete:\n' "$n_subsys_errs"
      jq -r '.documentation.subsystem_errors[] | "      - " + .subsystem + ": " + .error' <<<"$report"
    fi

    printf '\n'
  } >&2
}

if $json_out; then
  printf '%s\n' "$report"
  exit 0
fi

render_report

# Combined exit codes:
#   0 — clean
#   4 — warnings only (misconfigured / non-compliant / doc warns / MCP unverified)
#   5 — critical (missing hygiene files OR broken internal links OR CLAUDE.md error)
has_critical=false
has_warn=false

(( n_missing > 0 )) && has_critical=true
(( n_broken > 0 )) && has_critical=true
[[ "$claude_md_status" == "error" ]] && has_critical=true

(( n_mis > 0 )) && has_warn=true
(( n_off > 0 )) && has_warn=true
(( n_orphans > 0 )) && has_warn=true
(( n_stale > 0 )) && has_warn=true
# Subsystem-execution failures are warnings, not criticals. They
# signify "the report is incomplete" rather than a detected problem in
# the target repo itself; the operator needs to know the checker was
# unable to answer the question.
(( n_subsys_errs > 0 )) && has_warn=true
[[ "$claude_md_status" == "warn" || "$claude_md_status" == "absent" ]] && has_warn=true

if ! $has_critical && ! $has_warn; then
  nyann::log "no drift detected"
  exit 0
fi

if $report_only; then
  if $has_critical; then exit 5; else exit 4; fi
fi

# Remediation offer: only MISSING items are auto-fixable in this version —
# MISCONFIGURED require content-level edits (handled incrementally via
# bootstrap.sh's scaffolders and gitignore combiner), and NON-COMPLIANT
# HISTORY is intentionally informational.
# Backticks in the user-facing remediation message are literal markdown,
# not shell command substitution. Single-quoting is intentional.
# shellcheck disable=SC2016
{
  printf 'Proposed remediation:\n'
  printf '  Re-run bootstrap.sh against this target with the profile so:\n'
  printf '    - gitignore combiner fills missing stack-typical entries\n'
  printf '    - hook installer writes any missing Husky / pre-commit.com files\n'
  printf '    - doc scaffolder fills missing docs/ + memory/ files\n'
  printf '    - CLAUDE.md router block is (re)generated\n'
  printf '  All writes are idempotent; existing user content is preserved.\n'
  printf '\nRun `/nyann:bootstrap` (or bin/bootstrap.sh) against this target to apply.\n'
  printf 'NON-COMPLIANT HISTORY: history rewrites are out of scope. Flag only.\n\n'
} >&2

if $has_critical; then exit 5; else exit 4; fi
