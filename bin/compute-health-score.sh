#!/usr/bin/env bash
# compute-health-score.sh — compute a health score from a DriftReport JSON.
#
# Usage:
#   compute-health-score.sh --drift-report <path>
#   compute-drift.sh ... | compute-health-score.sh
#
# Output: JSON with score (0-100), breakdown, and max_deductions.
# Exit code: always 0 (scoring never fails; missing fields default to 0).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

drift_report_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drift-report)   drift_report_path="${2:-}"; shift 2 ;;
    --drift-report=*) drift_report_path="${1#--drift-report=}"; shift ;;
    -h|--help)        sed -n '3,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# Read from file or stdin
if [[ -n "$drift_report_path" && -f "$drift_report_path" ]]; then
  drift_json=$(cat "$drift_report_path")
elif [[ ! -t 0 ]]; then
  drift_json=$(cat)
else
  nyann::die "usage: compute-health-score.sh --drift-report <path> or pipe via stdin"
fi

# Validate it's JSON
jq -e . <<<"$drift_json" >/dev/null 2>&1 || nyann::die "invalid JSON input"

# --- Compute deductions from the health score ---
# Base: 100
# Missing file: -8 per item
# Misconfigured file: -4 per item
# Non-compliant commit: -1 per commit (cap -15)
# Broken link: -5 per link
# CLAUDE.md warn: -3; error: -10
# Orphan doc: -2 per file
# Stale doc: -1 per file
# Subsystem error: -2 per error
# Floor: 0

jq '
  def clamp(min; max): if . < min then min elif . > max then max else . end;

  . as $dr |

  ($dr.missing // [] | length) as $missing_count |
  ($dr.misconfigured // [] | length) as $misconfigured_count |
  ($dr.non_compliant_history.offenders // [] | length) as $noncompliant_count |
  ($dr.documentation.links.broken // [] | length) as $broken_links |
  ($dr.documentation.orphans.orphans // [] | length) as $orphans |
  ($dr.documentation.staleness.stale // [] | length) as $stale |
  ($dr.documentation.claude_md // {}) as $claude_md |
  ($dr.documentation.subsystem_errors // [] | length) as $subsystem_errors |

  (($claude_md.status // "ok") as $st |
   if $st == "error" then -10
   elif $st == "warn" then -3
   else 0 end) as $claude_md_deduction |

  # Individual deductions
  ($missing_count * -8) as $missing_ded |
  ($misconfigured_count * -4) as $misconfigured_ded |
  ([$noncompliant_count * -1, -15] | max) as $noncompliant_ded |
  ($broken_links * -5) as $broken_links_ded |
  ($orphans * -2) as $orphans_ded |
  ($stale * -1) as $stale_ded |
  ($subsystem_errors * -2) as $subsystem_ded |

  (100 + $missing_ded + $misconfigured_ded + $noncompliant_ded +
   $broken_links_ded + $claude_md_deduction + $orphans_ded +
   $stale_ded + $subsystem_ded) | clamp(0; 100) |

  {
    score: .,
    breakdown: {
      missing: $missing_ded,
      misconfigured: $misconfigured_ded,
      non_compliant: $noncompliant_ded,
      broken_links: $broken_links_ded,
      claude_md: $claude_md_deduction,
      orphans: $orphans_ded,
      stale: $stale_ded,
      subsystem_errors: $subsystem_ded
    },
    max_deductions: {
      missing: ($missing_count),
      misconfigured: ($misconfigured_count),
      non_compliant: ($noncompliant_count),
      broken_links: ($broken_links),
      orphans: ($orphans),
      stale: ($stale),
      subsystem_errors: ($subsystem_errors)
    }
  }
' <<<"$drift_json"
