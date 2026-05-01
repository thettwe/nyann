#!/usr/bin/env bash
# diff-profile.sh — structured diff between two nyann profiles.
#
# Usage:
#   diff-profile.sh <from> <to> [--user-root <dir>] [--plugin-root <dir>]
#                               [--format human|json]
#
# Loads both profiles via load-profile.sh, then computes a section-by-section
# diff: stack, branching, hooks, conventions, documentation, extras, ci,
# governance. Emits added/removed/changed items per section.
#
# Exit codes:
#   0 — diff computed (may be empty if profiles are identical)
#   1 — one or both profiles not found or bad arguments

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

from_name=""
to_name=""
user_root="${HOME}/.claude/nyann"
plugin_root="$(cd "${_script_dir}/.." && pwd)"
fmt="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)     user_root="${2:-}"; shift 2 ;;
    --user-root=*)   user_root="${1#--user-root=}"; shift ;;
    --plugin-root)   plugin_root="${2:-}"; shift 2 ;;
    --plugin-root=*) plugin_root="${1#--plugin-root=}"; shift ;;
    --format)        fmt="${2:-json}"; shift 2 ;;
    --format=*)      fmt="${1#--format=}"; shift ;;
    -h|--help)       sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    --*)             nyann::die "unknown flag: $1" ;;
    *)
      if [[ -z "$from_name" ]]; then
        from_name="$1"
      elif [[ -z "$to_name" ]]; then
        to_name="$1"
      else
        nyann::die "unexpected extra arg: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$from_name" ]] || nyann::die "usage: diff-profile.sh <from> <to>"
[[ -n "$to_name" ]]   || nyann::die "usage: diff-profile.sh <from> <to>"

case "$fmt" in
  human|json) ;;
  *) nyann::die "--format must be human|json" ;;
esac

# --- load profiles ----------------------------------------------------------

_diff_tmpfiles=("")
_diff_cleanup() { rm -f "${_diff_tmpfiles[@]}" 2>/dev/null || true; }
trap _diff_cleanup EXIT

load_one() {
  local name="$1"
  local tmp_out tmp_err
  tmp_out=$(mktemp -t nyann-diff-load.XXXXXX)
  tmp_err=$(mktemp -t nyann-diff-err.XXXXXX)
  _diff_tmpfiles+=("$tmp_out" "$tmp_err")
  if ! "${_script_dir}/load-profile.sh" "$name" \
       --user-root "$user_root" --plugin-root "$plugin_root" \
       > "$tmp_out" 2> "$tmp_err"; then
    cat "$tmp_err" >&2
    nyann::die "failed to load profile: $name"
  fi
  cat "$tmp_out"
}

from_json=$(load_one "$from_name")
to_json=$(load_one "$to_name")

# Strip _meta before diffing (loader metadata, not profile content).
from_json=$(jq 'del(._meta)' <<<"$from_json")
to_json=$(jq 'del(._meta)' <<<"$to_json")

# --- compute diff -----------------------------------------------------------

diff_result=$(jq -n \
  --arg from "$from_name" \
  --arg to "$to_name" \
  --argjson f "$from_json" \
  --argjson t "$to_json" \
'
def array_diff(a; b):
  { added: (b - a), removed: (a - b) };

def scalar_change(section; key):
  (section + "." + key) as $path |
  ($f | getpath($path | split(".")) // null) as $fv |
  ($t | getpath($path | split(".")) // null) as $tv |
  if $fv == $tv then null
  else {field: key, from: $fv, to: $tv}
  end;

# Stack changes.
([
  scalar_change("stack"; "primary_language"),
  scalar_change("stack"; "framework"),
  scalar_change("stack"; "package_manager")
] | map(select(. != null))) as $stack_changes |

# Branching changes.
([
  scalar_change("branching"; "strategy"),
  (if ($f.branching.base_branches // []) != ($t.branching.base_branches // []) then
    {field: "base_branches",
     from: ($f.branching.base_branches // []),
     to: ($t.branching.base_branches // [])}
  else null end)
] | map(select(. != null))) as $branching_changes |

# Hook diffs per slot.
(["pre_commit", "commit_msg", "pre_push"] | map(
  . as $slot |
  array_diff(($f.hooks[$slot] // []); ($t.hooks[$slot] // [])) |
  if (.added | length) > 0 or (.removed | length) > 0 then
    {slot: $slot, added: .added, removed: .removed}
  else null end
) | map(select(. != null))) as $hooks_changes |

# Conventions.
([
  scalar_change("conventions"; "commit_format"),
  (if ($f.conventions.commit_scopes // []) != ($t.conventions.commit_scopes // []) then
    {field: "commit_scopes",
     from: ($f.conventions.commit_scopes // []),
     to: ($t.conventions.commit_scopes // [])}
  else null end)
] | map(select(. != null))) as $conventions_changes |

# Documentation.
([
  scalar_change("documentation"; "storage_strategy"),
  scalar_change("documentation"; "claude_md_mode"),
  scalar_change("documentation"; "claude_md_size_budget_kb"),
  scalar_change("documentation"; "adr_format"),
  scalar_change("documentation"; "staleness_days"),
  (if ($f.documentation.scaffold_types // []) != ($t.documentation.scaffold_types // []) then
    {field: "scaffold_types",
     from: ($f.documentation.scaffold_types // []),
     to: ($t.documentation.scaffold_types // [])}
  else null end)
] | map(select(. != null))) as $documentation_changes |

# Extras.
(($f.extras // {}) | keys) + (($t.extras // {}) | keys) | unique |
map(
  . as $k |
  (($f.extras // {})[$k] // null) as $fv |
  (($t.extras // {})[$k] // null) as $tv |
  if $fv == $tv then null
  else {field: $k, from: $fv, to: $tv}
  end
) | map(select(. != null)) | . as $extras_changes |

# CI.
([
  scalar_change("ci"; "enabled")
] | map(select(. != null))) as $ci_changes |

# Governance.
([
  scalar_change("governance"; "enabled"),
  scalar_change("governance"; "threshold"),
  scalar_change("governance"; "severity"),
  (if ($f.governance.ignore // []) != ($t.governance.ignore // []) then
    {field: "ignore",
     from: ($f.governance.ignore // []),
     to: ($t.governance.ignore // [])}
  else null end)
] | map(select(. != null))) as $governance_changes |

# GitHub integration.
(($f.github // {}) | keys) + (($t.github // {}) | keys) | unique |
map(
  . as $k |
  (($f.github // {})[$k] // null) as $fv |
  (($t.github // {})[$k] // null) as $tv |
  if $fv == $tv then null
  else {field: $k, from: $fv, to: $tv}
  end
) | map(select(. != null)) | . as $github_changes |

# Release.
(($f.release // {}) | keys) + (($t.release // {}) | keys) | unique |
map(
  . as $k |
  (($f.release // {})[$k] // null) as $fv |
  (($t.release // {})[$k] // null) as $tv |
  if $fv == $tv then null
  else {field: $k, from: $fv, to: $tv}
  end
) | map(select(. != null)) | . as $release_changes |

# Summary.
([$stack_changes, $branching_changes, $hooks_changes, $conventions_changes,
  $documentation_changes, $extras_changes, $ci_changes, $governance_changes,
  $github_changes, $release_changes] |
  map(length) | add) as $total_changes |

{
  from: $from,
  to: $to,
  identical: ($total_changes == 0),
  total_changes: $total_changes,
  sections: {
    stack: $stack_changes,
    branching: $branching_changes,
    hooks: $hooks_changes,
    conventions: $conventions_changes,
    documentation: $documentation_changes,
    extras: $extras_changes,
    ci: $ci_changes,
    governance: $governance_changes,
    github: $github_changes,
    release: $release_changes
  }
}
')

if [[ "$fmt" == "json" ]]; then
  printf '%s\n' "$diff_result"
else
  from_display=$(jq -r '.from' <<<"$diff_result")
  to_display=$(jq -r '.to' <<<"$diff_result")
  identical=$(jq -r '.identical' <<<"$diff_result")
  total=$(jq '.total_changes' <<<"$diff_result")

  printf 'Profile Diff: %s → %s\n' "$from_display" "$to_display"
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

  if [[ "$identical" == "true" ]]; then
    printf 'Profiles are identical.\n'
    exit 0
  fi

  printf '%d change(s) found.\n\n' "$total"

  # Stack
  count=$(jq '.sections.stack | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Stack:\n'
    jq -r '.sections.stack[] | "  \(.field): \(.from // "null") → \(.to // "null")"' <<<"$diff_result"
    printf '\n'
  fi

  # Branching
  count=$(jq '.sections.branching | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Branching:\n'
    jq -r '.sections.branching[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # Hooks
  count=$(jq '.sections.hooks | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Hooks:\n'
    jq -r '.sections.hooks[] |
      "  [\(.slot)]" +
      (if (.added | length) > 0 then "\n    + " + (.added | join(", ")) else "" end) +
      (if (.removed | length) > 0 then "\n    - " + (.removed | join(", ")) else "" end)
    ' <<<"$diff_result"
    printf '\n'
  fi

  # Conventions
  count=$(jq '.sections.conventions | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Conventions:\n'
    jq -r '.sections.conventions[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # Documentation
  count=$(jq '.sections.documentation | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Documentation:\n'
    jq -r '.sections.documentation[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # Extras
  count=$(jq '.sections.extras | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Extras:\n'
    jq -r '.sections.extras[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # CI
  count=$(jq '.sections.ci | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'CI:\n'
    jq -r '.sections.ci[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # Governance
  count=$(jq '.sections.governance | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Governance:\n'
    jq -r '.sections.governance[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # GitHub
  count=$(jq '.sections.github | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'GitHub:\n'
    jq -r '.sections.github[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi

  # Release
  count=$(jq '.sections.release | length' <<<"$diff_result")
  if (( count > 0 )); then
    printf 'Release:\n'
    jq -r '.sections.release[] | "  \(.field): \(.from) → \(.to)"' <<<"$diff_result"
    printf '\n'
  fi
fi
