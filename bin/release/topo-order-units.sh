#!/usr/bin/env bash
# topo-order-units.sh — emit IaC unit paths in dependency-FIRST topological
# order so a bumped module is tagged BEFORE a chart that references it.
#
# Usage:
#   topo-order-units.sh [--units-file <path>]        # else reads units JSON on stdin
#
# Input: the descriptor's iac.units[] array:
#   [ { kind, path, name, version?, depends_on? }, ... ]
# `depends_on` edge values are a sibling unit's NAME (when unambiguous) else a
# repo-relative PATH — exactly the emit contract from discover-iac-units.sh.
#
# Output: one unit PATH per line, in topological order. A unit B that another
# unit A depends_on is emitted BEFORE A (so B is released/tagged first).
#
# Edge resolution mirrors discover-iac-units.sh's _iac_graph_break_cycles:
#   value is an exact unit path          -> that path
#   value matches exactly one unit name  -> that unit's path
#   value matches >1 names               -> MOST-LOCAL (longest shared leading
#                                           dir prefix with the source); ties
#                                           are dropped (no edge)
#   no match (external/dangling)         -> no internal edge
#
# Cycle handling: the discover layer already cycle-breaks before emit, so input
# is normally a DAG. We re-guard anyway — a residual cycle is NOT fatal: we emit
# a best-effort order (Kahn's algorithm, then any leftover nodes in input order)
# and warn. NEVER abort. (Spec: "reuse cycle handling — warn + best-effort
# order, never abort".)

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

units_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --units-file)   units_file="${2:-}"; shift 2 ;;
    --units-file=*) units_file="${1#--units-file=}"; shift ;;
    -h|--help)      sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "topo-order-units: unknown argument: $1" ;;
  esac
done

if [[ -n "$units_file" ]]; then
  [[ -f "$units_file" ]] || nyann::die "topo-order-units: --units-file not found: $units_file"
  units_json=$(cat "$units_file")
else
  units_json=$(cat)
fi

# Empty / non-array input -> nothing to order (emit nothing, exit clean).
if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$units_json"; then
  exit 0
fi

# Build adjacency (resolved to PATHS) + Kahn-sort + cycle-safe leftover append,
# all in jq. We compute, per node path, the set of paths it depends_on
# (dependency-first means deps come BEFORE dependents in the output).
#
# `cycled` is set true when Kahn cannot drain all nodes (a residual cycle);
# the shell layer warns once based on it.
result=$(jq -c '
  . as $units
  | [ $units[].path ] as $paths
  | ( reduce $units[] as $u ({}; .[$u.name] += [$u.path]) ) as $by_name

  # resolve one edge value (name-or-path) from source path $src -> target path
  | def resolve($val; $src):
      if ($paths | index($val)) != null then $val
      else
        ($by_name[$val] // []) as $cands
        | if ($cands | length) == 1 then $cands[0]
          elif ($cands | length) > 1 then
            # most-local: longest shared leading directory prefix with $src.
            ( $src | split("/") ) as $sd
            | ( [ $cands[]
                  | . as $c
                  | ( $c | split("/") ) as $cd
                  | { p: $c,
                      score: ( [ range(0; ([($sd|length),($cd|length)] | min)) ]
                               | map(select($sd[.] == $cd[.])) | length ) } ]
                | sort_by(.score) | reverse ) as $ranked
            | if ($ranked | length) >= 2 and $ranked[0].score == $ranked[1].score
              then null            # tie -> drop edge (prefer missing over wrong)
              else $ranked[0].p end
          else null end
      end;

  # adjacency: deps[path] = unique resolved dependency paths (self-edges dropped)
  ( reduce $units[] as $u ({};
      .[$u.path] = ( [ ($u.depends_on // [])[]
                       | resolve(.; $u.path) ]
                     | map(select(. != null and . != $u.path))
                     | unique )
    ) ) as $deps

  # Kahn (dependency-first): repeatedly take nodes whose unemitted deps are all
  # already emitted. Preserve input order among ready nodes for stability.
  | { remaining: $paths, emitted: [], out: [] }
  | until ( (.remaining | length) == 0 or .stuck == true;
      .emitted as $em
      | ( [ .remaining[]
            | select( ($deps[.] // []) - $em | length == 0 ) ] ) as $ready
      | if ($ready | length) == 0 then .stuck = true
        else
          .out += $ready
          | .emitted += $ready
          | .remaining -= $ready
        end
    )
  # Residual cycle: append leftover nodes in input order, flag cycled.
  | { order: (.out + .remaining),
      cycled: ((.remaining | length) > 0) }
' <<<"$units_json")

if [[ "$(jq -r '.cycled' <<<"$result")" == "true" ]]; then
  nyann::warn "topo-order-units: dependency cycle(s) survived discovery cycle-break; emitting best-effort order"
fi

jq -r '.order[]' <<<"$result"
