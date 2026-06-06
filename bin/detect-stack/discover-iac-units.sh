# detect-stack/discover-iac-units.sh — deep per-tool IaC unit + dependency
# discovery (v1.13.0 I7). Sourced by detect-iac.sh; also runnable standalone
# for tests / downstream tooling (see the `if [[ "${BASH_SOURCE[0]}" ... ]]`
# guard at the bottom).
#
# CONTRACT
#   nyann::discover_iac_units TARGET TOOL
#     TARGET — repo root (or monorepo subdir) to inspect (read-only).
#     TOOL   — the already-detected iac.tool: one of
#              terraform | opentofu | aws-cdk | pulumi | kustomize | helm |
#              ansible | kubernetes.
#   Prints to STDOUT a single JSON array of unit objects:
#       [ { "kind": <module|stack|chart|overlay|playbook|role>,
#           "path": <repo-relative path, "." for a root unit>,
#           "name": <unit name>,
#           "version": <string|null>,
#           "depends_on": [ <name-or-path of a sibling unit>, ... ] } ]
#     `depends_on` is OMITTED (not []) when a unit has no resolved local
#     dependency edges, so the no-edge output is byte-identical to what
#     detect-iac.sh emits today (back-compat: existing tests pass).
#   Also sets the global IAC_UNITS_JSON to that same array so detect-iac.sh
#   can fold the result into the descriptor the way sibling modules do.
#   Returns 0 always (an empty repo yields `[]`); never aborts, never hangs.
#
# WHY a separate module
#   detect-iac.sh stays the coarse "which tool is this" classifier; this file
#   owns the expensive, tool-specific graph walk. Keeping them apart lets the
#   graph logic grow (more tools, richer edges) without bloating the
#   precedence chain, and lets it be unit-tested in isolation.
#
# DEPENDS_ON semantics (for the I10 release-ordering topo-sort)
#   An edge A -> B means "A depends on B" (B must be released/applied first).
#   Edge values are the NAMES of sibling units when a name resolves
#   unambiguously, else the repo-relative PATH. Downstream consumers match an
#   edge against each unit's `name` first, then `path`.
#
# CYCLE SAFETY (spec risk: malformed repos can produce dependency cycles)
#   We reuse the house "visited set + max depth" idiom from load-profile.sh
#   (the `[[ " $seen " == *" $node "* ]]` membership test), but INVERT the
#   response: on a cycle or an over-deep chain we nyann::warn and DROP the
#   offending back-edge — emitting the flat unit list without that edge —
#   rather than nyann::die. Detection must never abort or hang on bad input.
#   Implemented in _iac_graph_break_cycles below as an iterative DFS, so there
#   is no unbounded recursion regardless of how pathological the input is.
#
# PERFORMANCE (spec: single-pass find + per-file grep; never a cloud CLI)
#   Each tool does ONE `find` to enumerate manifests, then a bounded `grep`
#   per manifest to extract edges. No per-unit `git log`, no shell-out to
#   terraform / cdk / pulumi / kubectl / helm / ansible (those need creds /
#   network and would make detection impure). Pure filesystem + jq + grep,
#   with a python3+PyYAML-gated fast path (via the helpers in detect-iac.sh)
#   for structured YAML where available and a grep fallback otherwise.
#
# DEEP DISCOVERY (this is the increment that lifts INC-1's root-only limit)
#   For CDK / Pulumi / Helm / Ansible, discovery recurses into a bounded set
#   of monorepo subdirs (the conventional infra holder dirs) so a CDK app
#   under infra/, a Helm umbrella under deploy/, etc. are all found — not just
#   the repo root. See _IAC_SUBDIR_ROOTS and per-tool notes.
#
# REMAINING LIMITATION (documented per spec)
#   - CDK stack DEPENDENCIES are not parsed: cross-stack edges in CDK live in
#     TS/Py/Go/C# constructor calls (addDependency()/props), which need a real
#     language parser. We emit CDK stacks WITHOUT depends_on; ordering for CDK
#     is left to `cdk` itself at deploy time. (Pure-filesystem constraint.)
#   - Pulumi inter-stack references (StackReference) likewise live in program
#     code, not the Pulumi.<stack>.yaml config, so Pulumi stacks carry no
#     depends_on either.
#   - Terraform remote module sources (registry / git / http) are recorded as
#     external and produce NO local edge (only `source = "./..."` /
#     `"../..."` relative paths become depends_on edges).

# Max dependency-chain depth before we treat the chain as runaway and stop
# walking it. This is a pure safety-net against a pathological/adversarial
# graph that the back-edge (cycle) detector somehow misses — NOT a limit on
# legitimately deep infra. A real acyclic linear chain can be arbitrarily long
# (e.g. layered envs) and MUST NOT lose edges, so the cap is set far above any
# realistic monorepo depth. Cycles are caught structurally (a back-edge to a
# node already on the DFS stack), independent of this number; the cap only ever
# fires on input far larger than any genuine infra tree.
_IAC_MAX_CHAIN_DEPTH=100000

# Conventional monorepo subdirs that may HOLD an IaC app/chart/roles tree.
# Used for deep (non-root) discovery of CDK / Pulumi / Helm / Ansible. The
# repo root (".") is always scanned too. Kept short + specific so the find
# stays cheap and we don't wander into application source trees.
_IAC_SUBDIR_ROOTS=(infra infrastructure deploy deployment deployments iac cdk pulumi ops charts ansible)

# Incremental unit collection (PERF). Earlier revisions re-serialized the whole
# growing array with a jq process on every _iac_du_add call — O(N^2) work plus
# one jq fork per unit, ~3s on a 200-module repo. We now accumulate each unit's
# raw fields into a single string buffer and assemble the array with ONE jq
# pass in _iac_du_assemble. Behavior/emit shape are byte-identical: dedup/
# self-edge/blank stripping and the depends_on-omitted shape are reproduced
# inside that single pass.
#
# DELIMITERS: ASCII Unit Separator (US, 0x1f) between the 5 fields and Record
# Separator (RS, 0x1e) between units. We CANNOT use NUL — bash strings and
# command substitution silently drop NUL bytes — but US/RS survive in a bash
# string and never occur in an IaC path, unit name, version, or compact JSON
# edge list, so splitting on them is unambiguous.
#
# NOTE: detect-iac discovery is pure / no-disk-write by contract, so we
# deliberately do NOT add an on-disk unit cache here; any cross-invocation cache
# belongs in a caller (e.g. the descriptor builder), not in this module.
#
# Record layout per unit:  kind US path US name US version US deps_json  RS
# version "" -> null; deps_json "" -> no edges.
_IAC_DU_US=$'\x1f'   # field separator
_IAC_DU_RS=$'\x1e'   # record separator
_IAC_DU_BUF=''

# _iac_du_emit — print the assembled units array (global _IAC_DU_JSON) to
# stdout and mirror it into IAC_UNITS_JSON for the sourcing detector.
_iac_du_emit() {
  IAC_UNITS_JSON="${_IAC_DU_JSON:-[]}"
  printf '%s\n' "$IAC_UNITS_JSON"
}

# _iac_du_add KIND PATH NAME [VERSION] [DEPENDS_JSON]
#   Buffer a unit's raw fields (no jq fork). VERSION empty -> null later.
#   DEPENDS_JSON is a JSON array string; "" / "[]" / "null" mean no edges. The
#   `depends_on` key is OMITTED at assembly when a unit has no resolved edges so
#   no-edge units stay byte-identical to the legacy shape.
_iac_du_add() {
  local _kind="$1" _path="$2" _name="$3" _ver="${4-}" _deps="${5-}"
  local _u="$_IAC_DU_US"
  _IAC_DU_BUF+="${_kind}${_u}${_path}${_u}${_name}${_u}${_ver}${_u}${_deps}${_IAC_DU_RS}"
}

# _iac_du_assemble — build _IAC_DU_JSON from the buffered records in a SINGLE
# jq pass. Reproduces the old per-unit normalization (drop blanks/self-edges,
# unique) and the depends_on-omitted shape exactly.
_iac_du_assemble() {
  if [[ -z "$_IAC_DU_BUF" ]]; then
    _IAC_DU_JSON='[]'
    return 0
  fi
  # Slurp the raw buffer (-sR), split into records on RS, then each record into
  # its 5 fields on US, and build each unit object in this one pass. The RS/US
  # separators are passed as args so no control byte sits in the jq program.
  _IAC_DU_JSON="$(printf '%s' "$_IAC_DU_BUF" \
    | jq -sRc --arg us "$_IAC_DU_US" --arg rs "$_IAC_DU_RS" '
    # Records end with RS, so the split leaves a trailing empty element - drop.
    ( split($rs) | map(select(. != "")) ) as $recs
    | [ $recs[]
        | split($us) as $f
        | { kind: $f[0], path: $f[1], name: $f[2], ver: $f[3], depsr: $f[4] } ]
    | map(
        ( if .ver == "" then null else .ver end ) as $v
        # Parse deps_json field; "" / "null" / parse-failure -> no edges.
        | ( if (.depsr == "" or .depsr == "null") then []
            else (.depsr | try fromjson catch []) end ) as $d0
        | (.name) as $nm | (.path) as $pp
        # Normalize: drop blanks, drop self-edges (by name or path), unique.
        # A self-edge would otherwise show up as a trivial 1-node cycle.
        | ( ($d0 // [])
            | map(select(. != "" and . != $nm and . != $pp))
            | unique ) as $d
        | ( {kind: .kind, path: .path, name: .name, version: $v}
            + (if ($d | length) > 0 then {depends_on: $d} else {} end) )
      )
  ' 2>/dev/null)"
  # Defensive: a jq hiccup must not leave the array empty/unset. Use an explicit
  # `if` (not `[[ ]] && ...`) so this function always returns 0 under errexit.
  if [[ -z "$_IAC_DU_JSON" ]]; then
    _IAC_DU_JSON='[]'
  fi
  return 0
}

# _iac_graph_break_cycles — given the assembled _IAC_DU_JSON (which may carry
# depends_on edges), detect cycles, and rewrite the array with the offending
# back-edges REMOVED. Pure jq + bash; iterative DFS (no recursion) so it cannot
# blow the stack on a pathological graph.
#
# NODE IDENTITY = PATH. Each unit's `path` is unique, but its `name` is NOT
# (e.g. modules/vpc and services/vpc both named "vpc"; two charts named
# "common"). Keying the graph on `name` collapsed distinct units into one node,
# fabricating self-loops and dropping legitimate edges on a clean DAG. So we
# resolve every edge value to the TARGET UNIT'S PATH before building adjacency,
# and run the DFS purely over paths.
#
# EDGE RESOLUTION (name-or-path edge value -> target path), per the emit
# contract (edges may be a sibling NAME when unambiguous, else a PATH):
#   1. value is an exact unit path           -> that path.
#   2. value matches exactly one unit NAME   -> that unit's path.
#   3. value matches >1 unit names           -> disambiguate to the MOST-LOCAL
#      candidate (the one sharing the longest leading directory prefix with the
#      source unit's path). If still tied, DO NOT create an edge — preferring a
#      missing edge over a wrong one (never collapse distinct nodes).
#   4. no match (external/dangling)          -> no internal edge.
# Unresolvable/ambiguous edges simply don't participate in cycle detection;
# they are NOT removed from the emitted output. Only true back-edges are.
#
# Algorithm: classic DFS edge classification over the path graph. An edge whose
# resolved target path is currently on the DFS stack is a BACK edge (closes a
# cycle) and is dropped. _IAC_MAX_CHAIN_DEPTH is a far-above-realistic safety
# net only: a legitimately deep ACYCLIC chain keeps every edge. We warn ONCE
# per dropped category. `dropped` records [source_path, original_edge_value] so
# the rewrite deletes the exact stored edge string (name- or path-form).
_iac_graph_break_cycles() {
  local graph="${_IAC_DU_JSON:-[]}"
  # Fast exit: no depends_on anywhere -> nothing to do (the common case).
  if ! jq -e 'any(.[]; has("depends_on"))' <<<"$graph" >/dev/null 2>&1; then
    return 0
  fi

  # Build a path-keyed adjacency map (resolving each edge to a target path) and
  # the ordered list of node paths, then run iterative DFS in jq to collect the
  # set of [from_path, original_edge_value] back-edges to drop.
  local result
  result="$(jq -c --argjson maxd "$_IAC_MAX_CHAIN_DEPTH" '
    . as $units
    # Count of shared LEADING path segments between segment-arrays $a and $b
    # (kept as its own def: a `range(...)` generator inside an array literal
    # confuses jq because range uses `;` as an arg separator).
    | def cpl($a; $b):
        reduce range(0; ([($a|length), ($b|length)] | min)) as $i
          (0; if (. == $i and $a[$i] == $b[$i]) then . + 1 else . end) ;
    ( reduce $units[] as $u ({}; .[$u.path] = true) ) as $byPath
    # name -> [paths] (a name may map to several units).
    | ( reduce $units[] as $u ({}; .[$u.name] += [$u.path]) ) as $byName
    # Resolve an edge value, as seen FROM $src (the source unit path), to a
    # target unit path, or null when it cannot be pinned to exactly one unit.
    | def resolve($src; $e):
        if ($byPath[$e] // false) then $e            # exact path
        else ($byName[$e] // []) as $cands
          | if ($cands | length) == 1 then $cands[0] # unambiguous name
            elif ($cands | length) > 1 then
              # Most-local: longest shared leading directory prefix with $src.
              ( ($src | split("/")) as $sp
                | ( $cands
                    | map( . as $c | { p: $c, s: cpl($sp; ($c | split("/"))) } )
                    | sort_by(.s) ) as $ranked
                | ($ranked[-1]) as $best
                | ( [ $ranked[] | select(.s == $best.s) ] | length ) as $ties
                | if $ties == 1 then $best.p else null end )  # tie -> no edge
            else null                                 # external/dangling
            end
        end ;
    # Adjacency keyed by path. Each entry: list of {to: target_path, via: edge}.
    ( reduce $units[] as $u ({};
        .[$u.path] = [ ($u.depends_on // [])[]
                       | . as $e | resolve($u.path; $e) as $t
                       | select($t != null) | {to: $t, via: $e} ] ) ) as $adj
    | [ $units[].path ] as $nodes
    # Iterative DFS over paths. Frames are [path, childIndex]. onstack spots
    # back edges; visited fully-explores each node once.
    | reduce $nodes[] as $start (
        {visited:{}, dropped:[], depthhit:false, cyclehit:false};
        if .visited[$start] then .
        else
          .stack = [[$start, 0]] | .onstack = {($start): true}
          | until( (.stack | length) == 0;
              .stack[-1] as $top
              | $top[0] as $node | $top[1] as $ci
              | ($adj[$node] // []) as $children
              | if $ci >= ($children | length)
                then
                  # Done with $node: pop it.
                  .visited[$node] = true
                  | .onstack = (.onstack | del(.[$node]))
                  | .stack = .stack[0:-1]
                else
                  $children[$ci] as $edge
                  | $edge.to as $child
                  | .stack[-1][1] = ($ci + 1)        # advance child cursor
                  | if (.onstack[$child] // false)
                    then
                      # Back edge -> cycle. Drop the literal stored edge value.
                      .dropped += [[$node, $edge.via]] | .cyclehit = true
                    elif (.stack | length) >= $maxd
                    then
                      # Safety net only (see _IAC_MAX_CHAIN_DEPTH). A genuine
                      # acyclic chain never reaches this on real infra.
                      .dropped += [[$node, $edge.via]] | .depthhit = true
                    elif (.visited[$child] // false)
                    then .                            # already fully explored
                    else
                      # Descend.
                      .stack += [[$child, 0]] | .onstack[$child] = true
                    end
                end
            )
          | del(.stack) | del(.onstack)
        end
      )
    | {dropped: (.dropped | unique), depthhit: .depthhit, cyclehit: .cyclehit}
  ' <<<"$graph" 2>/dev/null)"

  [[ -z "$result" ]] && return 0
  local dropped depthhit cyclehit
  dropped="$(jq -c '.dropped' <<<"$result" 2>/dev/null)"
  depthhit="$(jq -r '.depthhit' <<<"$result" 2>/dev/null)"
  cyclehit="$(jq -r '.cyclehit' <<<"$result" 2>/dev/null)"

  if [[ "$dropped" == "[]" || -z "$dropped" ]]; then
    return 0
  fi

  # Warn accurately: cycles and the depth cap are distinct hazards (the same
  # run can hit both). Either way we emit the flat list minus the bad edges.
  local _ndrop
  _ndrop="$(jq 'length' <<<"$dropped" 2>/dev/null)"
  if [[ "$cyclehit" == "true" ]]; then
    nyann::warn "iac units: dependency cycle(s) detected; emitting flat list without the cycling edge(s)"
  fi
  if [[ "$depthhit" == "true" ]]; then
    nyann::warn "iac units: dependency chain exceeds max depth ${_IAC_MAX_CHAIN_DEPTH}; emitting flat list without the over-deep edge(s)"
  fi
  nyann::log "iac units: dropped ${_ndrop} dependency edge(s) to keep the graph acyclic"

  # Rewrite: remove each dropped [source_path, edge_value] edge. The edge value
  # stored is the literal one we matched on during the DFS, so we match it
  # directly (no name<->path remapping needed). Empty depends_on arrays are
  # removed entirely so the unit reverts to the no-edge (legacy) shape.
  _IAC_DU_JSON="$(jq -c --argjson dropped "$dropped" '
    ( reduce $dropped[] as $d ({}; .[$d[0]] += [$d[1]]) ) as $drop
    | map(
        if (.depends_on != null) and ($drop[.path] != null)
        then
          ($drop[.path]) as $vias
          | .depends_on = (.depends_on | map(select(. as $e | ($vias | index($e)) == null)))
          | if (.depends_on | length) == 0 then del(.depends_on) else . end
        else .
        end
      )
  ' <<<"$graph" 2>/dev/null)"
  # Defensive: if the rewrite produced nothing (e.g. jq hiccup), keep the
  # original graph rather than losing all units. Use an explicit `if` so this
  # function always returns 0 under `set -o errexit` (a trailing `[[ ]] && ..`
  # that evaluates false would otherwise abort the whole script).
  if [[ -z "$_IAC_DU_JSON" ]]; then
    _IAC_DU_JSON="$graph"
  fi
  return 0
}

# =============================================================================
# Per-tool discovery
# =============================================================================

# --- Terraform / OpenTofu ----------------------------------------------------
# modules/* with *.tf -> kind=module. root (if it holds *.tf) and
# environments/* | envs/* -> kind=stack (deployable). Parse
# `module "x" { source = "..." }`; a LOCAL relative source ("./.." / "../..")
# becomes a depends_on edge to the module living at the resolved path.
_iac_du_terraform() {
  local target="$1"
  # Single-pass enumeration of every *.tf (excluding the vendor .terraform/
  # cache), capped at a sane depth. We bucket files by their containing dir,
  # then classify each dir as module / stack. bash 3.2 has no associative
  # arrays, so we dedup the dir list with sort -u (one pass over the find
  # output) and iterate the unique dirs.
  local _tf_dirs
  _tf_dirs="$(find "$target" -maxdepth 6 -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null \
              | while IFS= read -r _tf; do [[ -n "$_tf" ]] && dirname "$_tf"; done \
              | sort -u)"

  # If nothing matched, emit nothing (caller already classified as terraform
  # on a shallower probe; absence here just means no parseable units).
  [[ -z "$_tf_dirs" ]] && return 0

  # For each tf dir, gather its local module-source edges in one grep pass.
  local _dir _rel _name _kind _deps
  while IFS= read -r _dir; do
    [[ -z "$_dir" ]] && continue
    _rel="${_dir#"$target"}"; _rel="${_rel#/}"
    [[ -z "$_rel" ]] && _rel="."
    # Classify by path convention. modules/<x> => module; environments|envs
    # => stack; root => stack; everything else with *.tf => module (a named
    # reusable dir) UNLESS it's the deployable root.
    case "/$_rel/" in
      */modules/*) _kind="module" ;;
      */environments/*|*/envs/*|*/environment/*) _kind="stack" ;;
      *) if [[ "$_rel" == "." ]]; then _kind="stack"; else _kind="module"; fi ;;
    esac
    if [[ "$_rel" == "." ]]; then _name="$(basename "$target")"; else _name="$(basename "$_rel")"; fi

    # Parse local module sources in this dir's *.tf files. A source like
    # "../networking" resolves relative to THIS dir; we record the resolved
    # repo-relative path as the edge (downstream maps path->name).
    _deps='[]'
    local _src _resolved
    while IFS= read -r _src; do
      [[ -z "$_src" ]] && continue
      # Only LOCAL sources start with ./ or ../ . Registry/git/http are external.
      case "$_src" in
        ./*|../*) : ;;
        *) continue ;;
      esac
      # Resolve "$_dir/$_src" to a repo-relative path without touching disk
      # (the module dir may legitimately exist; we don't need to stat it).
      _resolved="$(_iac_norm_relpath "$target" "$_dir" "$_src")"
      [[ -n "$_resolved" ]] && _deps="$(jq -c --arg p "$_resolved" '. + [$p]' <<<"$_deps")"
    done < <(_iac_tf_module_sources "$_dir")

    _iac_du_add "$_kind" "$_rel" "$_name" "" "$_deps"
  done <<<"$_tf_dirs"
}

# _iac_tf_module_sources DIR — echo the source string of every
# `module "..." { ... source = "..." }` declared in DIR's *.tf files, one per
# line. Single grep+sed pass per file (no HCL parser). Handles BOTH the
# own-line form (`  source = "../foo"`) and the inline single-line module form
# (`module "x" { source = "../foo" }`): `source` may be preceded by a `{` or
# whitespace, so we anchor on a leading `{`/whitespace + the `source` keyword
# rather than line-start. A leading word char before `source` (e.g.
# `data_source`) is excluded so we don't capture lookalike attributes.
_iac_tf_module_sources() {
  local dir="$1" f
  for f in "$dir"/*.tf; do
    [[ -f "$f" ]] || continue
    grep -Eo '(^|[[:space:]{])source[[:space:]]*=[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
      | sed -E 's/.*source[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/'
  done
}

# _iac_norm_relpath TARGET BASEDIR REL — resolve REL (a ./.. relative path)
# against BASEDIR and return it repo-relative to TARGET, collapsing . and ..
# segments lexically (no realpath/stat — the path need not exist yet). When the
# path ESCAPES the repo root (more `..` than there are leading segments, e.g.
# `../../../../etc/passwd`), we print NOTHING (and still return 0) rather than
# clamping at the root — clamping would fabricate a bogus repo-relative edge
# (e.g. `etc/passwd`) to a unit that does not exist. Callers guard on a
# non-empty result, so an escaping source simply produces no edge. (Empty
# output is the unambiguous escape signal: a valid root resolves to ".", never
# the empty string. We return 0 even on escape so the `_resolved="$(...)"`
# assignment doesn't trip `set -o errexit` in the caller.)
_iac_norm_relpath() {
  local target="$1" basedir="$2" rel="$3"
  # Start from basedir's repo-relative segments.
  local base_rel="${basedir#"$target"}"; base_rel="${base_rel#/}"
  local -a parts=()
  local seg
  if [[ -n "$base_rel" ]]; then
    local IFS='/'
    for seg in $base_rel; do parts+=("$seg"); done
  fi
  local IFS='/'
  for seg in $rel; do
    case "$seg" in
      ''|'.') : ;;
      '..')
        if ((${#parts[@]} > 0)); then
          unset 'parts[${#parts[@]}-1]'
        else
          # Escapes above the repo root — refuse to fabricate an edge. Print
          # nothing; the caller's non-empty guard drops the would-be edge.
          return 0
        fi
        ;;
      *) parts+=("$seg") ;;
    esac
  done
  # Re-pack (unset leaves index holes).
  local -a packed=()
  for seg in "${parts[@]+"${parts[@]}"}"; do packed+=("$seg"); done
  ((${#packed[@]} == 0)) && { printf '.'; return 0; }
  printf '%s' "${packed[*]}"
}

# --- Helm --------------------------------------------------------------------
# Chart.yaml root (kind=chart) + charts/*/Chart.yaml subcharts (deep: also
# under monorepo subdir roots). depends_on edges come SOLELY from the umbrella
# Chart.yaml `dependencies:` list (each entry's `name:`). A subchart vendored
# physically under charts/ does NOT by itself create an edge — only an explicit
# `dependencies:` entry does. (Helm requires the dependency be declared there
# regardless; a bare charts/ dir with no matching entry is not auto-linked.)
_iac_du_helm() {
  local target="$1"
  local _cf
  # Single find: every Chart.yaml under target (bounded depth), across the
  # repo root and the conventional subdir roots.
  while IFS= read -r _cf; do
    [[ -f "$_cf" ]] || continue
    local _cdir _rel _name _ver _deps
    _cdir="$(dirname "$_cf")"
    _rel="${_cdir#"$target"}"; _rel="${_rel#/}"
    [[ -z "$_rel" ]] && _rel="."
    _name="$(_iac_yaml_key "$_cf" name)"
    [[ -z "$_name" ]] && _name="$(basename "$_cdir")"
    _ver="$(_iac_yaml_key "$_cf" version)"
    # dependencies: -> list of name: values. depends_on holds those names.
    _deps="$(_iac_yaml_list_field "$_cf" dependencies name)"
    _iac_du_add chart "$_rel" "$_name" "$_ver" "$_deps"
  done < <(_iac_find_manifests "$target" Chart.yaml Chart.yml)
}

# --- Kustomize ---------------------------------------------------------------
# overlays/*/kustomization.yaml -> kind=overlay (deep: also under subdir
# roots). Parse `bases:` / `resources:` — entries that point at a base dir
# become depends_on edges (resolved repo-relative). Only DIR references (not
# inline manifest .yaml files) are treated as base edges.
_iac_du_kustomize() {
  local target="$1"
  local _kf
  while IFS= read -r _kf; do
    [[ -f "$_kf" ]] || continue
    local _kdir _rel _name
    _kdir="$(dirname "$_kf")"
    _rel="${_kdir#"$target"}"; _rel="${_rel#/}"
    [[ -z "$_rel" ]] && _rel="."
    # Only overlays/* dirs are emitted as units (matches detect-iac.sh today;
    # base/root kustomizations are referenced, not versioned units).
    case "/$_rel/" in
      */overlays/*) : ;;
      *) continue ;;
    esac
    _name="$(basename "$_kdir")"
    # bases: + resources: entries that resolve to a DIRECTORY become edges.
    local _deps='[]' _ref _resolved
    while IFS= read -r _ref; do
      [[ -z "$_ref" ]] && continue
      case "$_ref" in
        http://*|https://*|git@*|git::*|ssh://*) continue ;;  # remote base — no local edge
        *) : ;;                            # ./.. or bare relative (e.g. "base")
      esac
      _resolved="$(_iac_norm_relpath "$target" "$_kdir" "$_ref")"
      # Treat as a base edge only if it resolves to a directory (a base),
      # not a plain manifest file living next to the overlay.
      if [[ -n "$_resolved" && -d "$target/$_resolved" ]]; then
        _deps="$(jq -c --arg p "$_resolved" '. + [$p]' <<<"$_deps")"
      fi
    done < <(_iac_kustomize_refs "$_kf")
    _iac_du_add overlay "$_rel" "$_name" "" "$_deps"
  done < <(_iac_find_manifests "$target" kustomization.yaml kustomization.yml)
}

# _iac_kustomize_refs FILE — echo every entry under a top-level `bases:` or
# `resources:` list, one per line (the `- value` items). Best-effort grep.
_iac_kustomize_refs() {
  local f="$1"
  # Capture `- item` lines that follow a bases:/resources: header until the
  # next top-level key. awk keeps it single-pass.
  awk '
    /^[[:space:]]*(bases|resources):[[:space:]]*$/ { inlist=1; next }
    /^[^[:space:]-]/ { inlist=0 }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      sub(/[[:space:]]*$/, "", line)
      gsub(/^["'\'']|["'\'']$/, "", line)
      if (line != "") print line
    }
  ' "$f" 2>/dev/null
}

# --- AWS CDK -----------------------------------------------------------------
# Stacks via lib/*-stack.{ts,py,go,cs} + bin/*.{ts,py} (deep: also under
# subdir roots). kind=stack, version null. No depends_on (see LIMITATION:
# CDK cross-stack edges live in program code, not parseable here).
_iac_du_cdk() {
  local target="$1"
  local _f _rel _name
  # Enumerate across root + subdir roots in one find, then filter to the CDK
  # stack-file shapes. We keep the legacy path/name shape exactly so existing
  # cdk tests (paths lib/foo-stack.ts, names foo-stack/app) keep passing.
  while IFS= read -r _f; do
    [[ -f "$_f" ]] || continue
    _rel="${_f#"$target"}"; _rel="${_rel#/}"
    _name="$(basename "$_f")"; _name="${_name%.*}"
    _iac_du_add stack "$_rel" "$_name"
  done < <(_iac_cdk_stack_files "$target")
}

# _iac_cdk_stack_files TARGET — echo every CDK stack source file: lib/*-stack.*
# and bin/*.{ts,py}, at the repo root AND under the conventional subdir roots.
_iac_cdk_stack_files() {
  local target="$1" root f
  local -a roots=(".")
  local r
  for r in "${_IAC_SUBDIR_ROOTS[@]}"; do
    [[ -d "$target/$r" ]] && roots+=("$r")
  done
  for root in "${roots[@]}"; do
    local base="$target"
    [[ "$root" != "." ]] && base="$target/$root"
    for f in "$base"/lib/*-stack.ts "$base"/lib/*-stack.py \
             "$base"/lib/*-stack.go "$base"/lib/*-stack.cs \
             "$base"/bin/*.ts "$base"/bin/*.py; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
  done
}

# --- Pulumi ------------------------------------------------------------------
# Pulumi.<stack>.yaml stacks (deep: also under subdir roots). kind=stack.
# No depends_on (StackReference lives in program code — see LIMITATION).
_iac_du_pulumi() {
  local target="$1"
  local _sf
  while IFS= read -r _sf; do
    [[ -f "$_sf" ]] || continue
    local _sdir _rel _base _stack
    _sdir="$(dirname "$_sf")"
    _rel="${_sdir#"$target"}"; _rel="${_rel#/}"
    _base="$(basename "$_sf")"
    case "$_base" in Pulumi.yaml|Pulumi.yml) continue ;; esac   # project file
    _stack="${_base#Pulumi.}"; _stack="${_stack%.yaml}"; _stack="${_stack%.yml}"
    # Path mirrors detect-iac.sh: root stacks keep the bare filename; nested
    # stacks carry the subdir prefix so they are addressable.
    local _path="$_base"
    [[ -n "$_rel" ]] && _path="$_rel/$_base"
    _iac_du_add stack "$_path" "$_stack"
  done < <(_iac_find_manifests "$target" 'Pulumi.*.yaml' 'Pulumi.*.yml')
}

# --- Ansible -----------------------------------------------------------------
# roles/* (kind=role) + playbooks (kind=playbook), deep across subdir roots.
# Edges: a playbook's `roles:` / `include_role:` / `import_role:` references,
# and a role's meta/main.yml `dependencies:` -> role names.
_iac_du_ansible() {
  local target="$1"
  # Roles: every roles/*/ dir under root or subdir roots. Edges from
  # meta/main.yml dependencies.
  local _rd
  while IFS= read -r _rd; do
    [[ -d "$_rd" ]] || continue
    local _rel _rname _deps
    _rel="${_rd#"$target"}"; _rel="${_rel#/}"; _rel="${_rel%/}"
    _rname="$(basename "$_rd")"
    _deps='[]'
    local _meta="$_rd/meta/main.yml"
    [[ -f "$_meta" ]] || _meta="$_rd/meta/main.yaml"
    if [[ -f "$_meta" ]]; then
      _deps="$(_iac_ansible_role_deps "$_meta")"
    fi
    _iac_du_add role "$_rel" "$_rname" "" "$_deps"
  done < <(_iac_find_role_dirs "$target")

  # Playbooks: top-level *.yml/*.yaml (root + subdir roots) shaped like a play
  # (hosts: + tasks:/roles:). Edges = referenced role names.
  local _pb
  while IFS= read -r _pb; do
    [[ -f "$_pb" ]] || continue
    grep -Eq '^[[:space:]]*-?[[:space:]]*hosts:' "$_pb" 2>/dev/null || continue
    grep -Eq '^[[:space:]]*(tasks|roles):' "$_pb" 2>/dev/null || continue
    local _rel _pbname _deps
    _rel="${_pb#"$target"}"; _rel="${_rel#/}"
    _pbname="$(basename "$_pb")"; _pbname="${_pbname%.*}"
    _deps="$(_iac_ansible_playbook_roles "$_pb")"
    _iac_du_add playbook "$_rel" "$_pbname" "" "$_deps"
  done < <(_iac_find_playbooks "$target")
}

# _iac_find_role_dirs TARGET — echo every roles/*/ dir at root + subdir roots.
_iac_find_role_dirs() {
  local target="$1" root d
  local -a roots=(".")
  local r
  for r in "${_IAC_SUBDIR_ROOTS[@]}"; do
    [[ -d "$target/$r" ]] && roots+=("$r")
  done
  for root in "${roots[@]}"; do
    local base="$target"
    [[ "$root" != "." ]] && base="$target/$root"
    for d in "$base"/roles/*/; do
      [[ -d "$d" ]] && printf '%s\n' "${d%/}"
    done
  done
}

# _iac_find_playbooks TARGET — echo every top-level *.yml/*.yaml at root +
# subdir roots (NOT recursing into roles/ — those are tasks, not playbooks).
_iac_find_playbooks() {
  local target="$1" root f
  local -a roots=(".")
  local r
  for r in "${_IAC_SUBDIR_ROOTS[@]}"; do
    [[ -d "$target/$r" ]] && roots+=("$r")
  done
  for root in "${roots[@]}"; do
    local base="$target"
    [[ "$root" != "." ]] && base="$target/$root"
    for f in "$base"/*.yml "$base"/*.yaml; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
  done
}

# _iac_ansible_playbook_roles FILE — echo role NAMES referenced from a
# playbook: items under a `roles:` list, plus `include_role:`/`import_role:`
# `name:` values. Best-effort awk/grep (no YAML parser needed for names).
_iac_ansible_playbook_roles() {
  local f="$1" out='[]'
  local _name
  # roles: list items — bare names or `- role: name` / `- name: name`.
  while IFS= read -r _name; do
    [[ -z "$_name" ]] && continue
    out="$(jq -c --arg n "$_name" '. + [$n]' <<<"$out")"
  done < <(awk '
    /^[[:space:]]*roles:[[:space:]]*$/ { inlist=1; next }
    /^[^[:space:]-]/ && !/^[[:space:]]*roles:/ { inlist=0 }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      # `- role: foo` or `- name: foo` -> foo; else bare `- foo`.
      if (line ~ /^(role|name):[[:space:]]*/) { sub(/^(role|name):[[:space:]]*/, "", line) }
      sub(/:.*$/, "", line)              # strip trailing `key:` of a mapping
      sub(/[[:space:]]*$/, "", line)
      gsub(/^["'\'']|["'\'']$/, "", line)
      if (line != "") print line
    }
  ' "$f" 2>/dev/null)
  # include_role:/import_role: name: foo
  while IFS= read -r _name; do
    [[ -z "$_name" ]] && continue
    out="$(jq -c --arg n "$_name" '. + [$n]' <<<"$out")"
  done < <(grep -E '^[[:space:]]*(include_role|import_role):' -A2 "$f" 2>/dev/null \
            | grep -E '^[[:space:]]*name:' \
            | sed -E 's/^[[:space:]]*name:[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')
  printf '%s' "$out"
}

# _iac_ansible_role_deps META — echo role names from a role meta/main.yml
# `dependencies:` list (each item is a role name or `- role: name`).
_iac_ansible_role_deps() {
  local f="$1" out='[]' _name
  while IFS= read -r _name; do
    [[ -z "$_name" ]] && continue
    out="$(jq -c --arg n "$_name" '. + [$n]' <<<"$out")"
  done < <(awk '
    /^[[:space:]]*dependencies:[[:space:]]*$/ { inlist=1; next }
    /^[^[:space:]-]/ { inlist=0 }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^(role|name):[[:space:]]*/) { sub(/^(role|name):[[:space:]]*/, "", line) }
      sub(/:.*$/, "", line)
      sub(/[[:space:]]*$/, "", line)
      gsub(/^["'\'']|["'\'']$/, "", line)
      if (line != "") print line
    }
  ' "$f" 2>/dev/null)
  printf '%s' "$out"
}

# =============================================================================
# Shared find / YAML helpers
# =============================================================================

# _iac_find_manifests TARGET PATTERN... — single `find` for the given filename
# patterns across the repo root AND the conventional subdir roots, bounded
# depth, vendor dirs pruned. Echoes matching file paths, one per line. This is
# the single-pass enumeration the perf budget calls for.
_iac_find_manifests() {
  local target="$1"; shift
  local -a name_args=()
  local p first=1
  for p in "$@"; do
    if ((first)); then name_args+=(-name "$p"); first=0
    else name_args+=(-o -name "$p"); fi
  done
  find "$target" -maxdepth 6 \
    \( -path '*/.git/*' -o -path '*/.terraform/*' -o -path '*/node_modules/*' \
       -o -path '*/.venv/*' -o -path '*/vendor/*' \) -prune -o \
    -type f \( "${name_args[@]}" \) -print 2>/dev/null
}

# _iac_yaml_list_field FILE FIELD ITEMKEY — echo a JSON array of the ITEMKEY
# scalar from each mapping under a top-level FIELD list. Used for Helm
# `dependencies: [ {name: x, ...}, ... ]` -> ["x", ...]. Prefers
# python3+PyYAML; falls back to awk for the common `- name: x` shape.
_iac_yaml_list_field() {
  local file="$1" field="$2" itemkey="$3"
  [[ -f "$file" ]] || { printf '[]'; return 0; }
  if nyann::has_python_yaml; then
    local out
    out=$(python3 - "$file" "$field" "$itemkey" <<'PY' 2>/dev/null || true
import sys, json, yaml
try:
    with open(sys.argv[1]) as fh:
        data = yaml.safe_load(fh) or {}
    items = data.get(sys.argv[2], []) if isinstance(data, dict) else []
    out = []
    if isinstance(items, list):
        for it in items:
            if isinstance(it, dict) and sys.argv[3] in it and it[sys.argv[3]]:
                out.append(str(it[sys.argv[3]]))
            elif isinstance(it, str):
                out.append(it)
    print(json.dumps(out))
except Exception:
    print("[]")
PY
)
    if [[ -n "$out" ]]; then printf '%s' "$out"; return 0; fi
  fi
  # awk fallback: under the FIELD: header, collect `ITEMKEY: value` from each
  # `- ...` block (and bare `- value` items) until the next top-level key.
  awk -v field="$field" -v itemkey="$itemkey" '
    $0 ~ "^[[:space:]]*" field ":[[:space:]]*$" { inlist=1; next }
    /^[^[:space:]-]/ { inlist=0 }
    inlist {
      line=$0
      sub(/[[:space:]]*#.*$/, "", line)
      # `- name: foo` (inline) or, on its own line, `  name: foo`.
      if (line ~ ("^[[:space:]]*-?[[:space:]]*" itemkey ":[[:space:]]*")) {
        sub("^[[:space:]]*-?[[:space:]]*" itemkey ":[[:space:]]*", "", line)
        sub(/[[:space:]]*$/, "", line)
        gsub(/^["'\'']|["'\'']$/, "", line)
        if (line != "") vals[n++]=line
      }
    }
    END {
      printf "["
      for (i=0;i<n;i++){ gsub(/\\/,"\\\\",vals[i]); gsub(/"/,"\\\"",vals[i]); printf "%s\"%s\"", (i?",":""), vals[i] }
      printf "]"
    }
  ' "$file" 2>/dev/null
}

# =============================================================================
# Entry point
# =============================================================================

# nyann::discover_iac_units TARGET TOOL — see file header for the contract.
nyann::discover_iac_units() {
  local target="${1-.}" tool="${2-}"
  _IAC_DU_JSON='[]'
  _IAC_DU_BUF=''
  # Normalize target: strip a trailing slash so path math stays consistent.
  target="${target%/}"
  [[ -z "$target" ]] && target="."

  case "$tool" in
    terraform|opentofu) _iac_du_terraform "$target" ;;
    helm)               _iac_du_helm "$target" ;;
    kustomize)          _iac_du_kustomize "$target" ;;
    aws-cdk)            _iac_du_cdk "$target" ;;
    pulumi)             _iac_du_pulumi "$target" ;;
    ansible)            _iac_du_ansible "$target" ;;
    kubernetes)         : ;;          # bare manifests carry no discrete units
    *)
      # Unknown tool: nothing to discover. Stay silent + emit [] (back-compat).
      : ;;
  esac

  # Assemble the buffered units into the array in a SINGLE jq pass (PERF).
  _iac_du_assemble
  # Cycle-safe pass: drop back-edges / over-deep edges, warn, never abort.
  _iac_graph_break_cycles
  _iac_du_emit
}

# Standalone invocation: `discover-iac-units.sh TARGET TOOL`. Sources _lib.sh
# and detect-iac.sh (for the shared _iac_yaml_key helper) when run directly,
# so it works in tests / downstream tooling without the full detect chain.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -o errexit -o nounset -o pipefail
  _du_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=../_lib.sh
  source "${_du_dir}/../_lib.sh"
  # shellcheck source=./detect-iac.sh
  source "${_du_dir}/detect-iac.sh"
  nyann::discover_iac_units "${1-.}" "${2-}"
fi
