#!/usr/bin/env bash
# merge-profiles.sh — deep-merge two profile JSON blobs (base + overlay).
#
# Usage:
#   merge-profiles.sh --base <file> --overlay <file>
#
# Merge rules:
#   - Scalars (string, number, boolean): overlay wins
#   - Objects: recursive merge, overlay keys win
#   - Arrays: overlay replaces entirely (no concatenation)
#   - null in overlay: explicit removal (field absent in output)
#   - Absent in overlay: inherited from base
#
# The `extends` field is stripped from the output (consumed, not inherited).
# `_meta` is stripped from both inputs (re-injected by load-profile.sh).
#
# Output: merged profile JSON on stdout.
#
# Exit codes:
#   0 — merged
#   2 — bad arguments

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

base_file=""
overlay_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)      base_file="${2:-}"; shift 2 ;;
    --base=*)    base_file="${1#--base=}"; shift ;;
    --overlay)   overlay_file="${2:-}"; shift 2 ;;
    --overlay=*) overlay_file="${1#--overlay=}"; shift ;;
    -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "merge-profiles: unknown argument: $1" ;;
  esac
done

[[ -n "$base_file" ]]    || nyann::die "merge-profiles: --base is required"
[[ -n "$overlay_file" ]] || nyann::die "merge-profiles: --overlay is required"
[[ -f "$base_file" ]]    || nyann::die "merge-profiles: base file not found: $base_file"
[[ -f "$overlay_file" ]] || nyann::die "merge-profiles: overlay file not found: $overlay_file"

# jq's `*` operator does recursive object merge (overlay wins for scalars).
# However, it also merges arrays element-by-element, which is not what we
# want — our spec says arrays replace entirely. We handle this by:
# 1. Do the recursive merge with `*`
# 2. Then for every key in the overlay that is an array, replace the merged
#    value with the overlay's array (stomping base).
# 3. Handle explicit null: keys set to null in overlay are removed.
# 4. Strip `extends` and `_meta` from output.
jq -n \
  --slurpfile base "$base_file" \
  --slurpfile overlay "$overlay_file" '
  # Recursively walk overlay to find array-typed and null-typed paths
  def array_paths:
    path(.. | arrays | select(. == .)) | select(length > 0);

  # Deep merge with overlay-wins semantics
  ($base[0] | del(.extends) | del(._meta)) as $b |
  ($overlay[0] | del(.extends) | del(._meta)) as $o |

  # Start with jq native recursive merge
  ($b * $o) as $merged |

  # Fix arrays: overlay arrays must replace, not element-merge.
  # Walk all paths in overlay that point to arrays and set them
  # from the overlay value, overriding the element-merged result.
  reduce ($o | [paths(type == "array")] | .[]) as $p (
    $merged;
    setpath($p; $o | getpath($p))
  ) |

  # Fix nulls: overlay keys explicitly set to null → remove from output.
  reduce ($o | [paths(. == null)] | .[]) as $p (
    .;
    delpaths([$p])
  )
'
