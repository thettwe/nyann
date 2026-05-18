#!/usr/bin/env bash
# detect-doc-conformance.sh — find docs that don't follow nyann conventions.
#
# Usage:
#   detect-doc-conformance.sh --target <repo> [--archetype <type>]
#
# Scans the repo for common documentation files that exist at
# non-standard paths relative to nyann's expected layout. Outputs a
# JSON array of proposed moves:
#   [{ "source": "relative/path", "target": "docs/architecture.md",
#      "category": "architecture", "confidence": 0.9,
#      "reason": "..." }]
#
# The archetype determines which targets are valid. Without it, all
# known nyann doc targets are candidates.
#
# Exit codes:
#   0 — scan complete (may produce empty array)
#   1 — bad input

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
archetype="unknown"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="${2:-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --archetype)   archetype="${2:-unknown}"; shift 2 ;;
    --archetype=*) archetype="${1#--archetype=}"; shift ;;
    -h|--help)     sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target must be an existing directory"
target="$(cd "$target" && pwd)"

# --- canonical paths (must match route-docs.sh declare_paths) ----------------

canonical_architecture="docs/architecture.md"
canonical_prd="docs/prd.md"
canonical_adrs="docs/decisions"
canonical_research="docs/research"
canonical_api_reference="docs/api-reference.md"
canonical_runbook="docs/runbook.md"
canonical_deployment="docs/deployment.md"
canonical_glossary="docs/glossary.md"

# --- archetype → which doc types are relevant --------------------------------

relevant_types="architecture prd adrs research"
case "$archetype" in
  api-service)  relevant_types="architecture prd adrs research api_reference runbook deployment glossary" ;;
  cli-tool)     relevant_types="architecture prd adrs research runbook" ;;
  library)      relevant_types="architecture prd adrs research api_reference glossary" ;;
  web-app)      relevant_types="architecture prd adrs research deployment" ;;
  mobile-app)   relevant_types="architecture prd adrs research deployment" ;;
  plugin)       relevant_types="architecture prd adrs research api_reference" ;;
  unknown)      relevant_types="architecture prd adrs research api_reference runbook deployment glossary" ;;
esac

# --- known non-conforming patterns -------------------------------------------
# Each pattern: <glob relative to target> → <category> <confidence> <reason>
# We check if the file/dir exists AND the canonical target does NOT exist
# (if canonical already exists, there's nothing to move to).

proposals='[]'

propose() {
  local source="$1" target_path="$2" category="$3" confidence="$4" reason="$5"
  proposals=$(jq --arg s "$source" --arg t "$target_path" \
    --arg c "$category" --argjson conf "$confidence" --arg r "$reason" \
    '. + [{source: $s, target: $t, category: $c, confidence: $conf, reason: $r}]' \
    <<<"$proposals")
}

check_and_propose() {
  local source_rel="$1" canonical="$2" category="$3" confidence="$4" reason="$5"

  # Only propose if category is relevant to archetype
  local is_relevant=false
  for rt in $relevant_types; do
    [[ "$rt" == "$category" ]] && { is_relevant=true; break; }
  done
  $is_relevant || return 0

  # Source must exist, canonical must NOT exist
  [[ -e "$target/$source_rel" ]] || return 0
  [[ -e "$target/$canonical" ]] && return 0

  # Don't propose moving a file to itself
  [[ "$source_rel" == "$canonical" ]] && return 0

  propose "$source_rel" "$canonical" "$category" "$confidence" "$reason"
}

# --- Architecture patterns ---------------------------------------------------

check_and_propose "ARCHITECTURE.md" "$canonical_architecture" \
  "architecture" 0.95 "Root-level ARCHITECTURE.md → nyann convention: docs/architecture.md"

check_and_propose "architecture.md" "$canonical_architecture" \
  "architecture" 0.95 "Root-level architecture.md → nyann convention: docs/architecture.md"

check_and_propose "doc/architecture.md" "$canonical_architecture" \
  "architecture" 0.9 "doc/ (singular) → nyann convention: docs/"

check_and_propose "documentation/architecture.md" "$canonical_architecture" \
  "architecture" 0.85 "documentation/ → nyann convention: docs/"

check_and_propose "design.md" "$canonical_architecture" \
  "architecture" 0.7 "design.md likely describes system architecture"

check_and_propose "DESIGN.md" "$canonical_architecture" \
  "architecture" 0.7 "DESIGN.md likely describes system architecture"

check_and_propose "docs/design.md" "$canonical_architecture" \
  "architecture" 0.75 "docs/design.md → nyann convention: docs/architecture.md"

check_and_propose "docs/system-design.md" "$canonical_architecture" \
  "architecture" 0.8 "docs/system-design.md → nyann convention: docs/architecture.md"

check_and_propose "docs/tech-architecture.md" "$canonical_architecture" \
  "architecture" 0.85 "docs/tech-architecture.md → nyann convention: docs/architecture.md"

# --- PRD patterns ------------------------------------------------------------

check_and_propose "PRD.md" "$canonical_prd" \
  "prd" 0.95 "Root-level PRD.md → nyann convention: docs/prd.md"

check_and_propose "prd.md" "$canonical_prd" \
  "prd" 0.95 "Root-level prd.md → nyann convention: docs/prd.md"

check_and_propose "spec.md" "$canonical_prd" \
  "prd" 0.7 "spec.md likely contains product requirements"

check_and_propose "SPEC.md" "$canonical_prd" \
  "prd" 0.7 "SPEC.md likely contains product requirements"

check_and_propose "docs/spec.md" "$canonical_prd" \
  "prd" 0.75 "docs/spec.md → nyann convention: docs/prd.md"

check_and_propose "docs/requirements.md" "$canonical_prd" \
  "prd" 0.8 "docs/requirements.md → nyann convention: docs/prd.md"

check_and_propose "requirements.md" "$canonical_prd" \
  "prd" 0.75 "Root-level requirements.md → nyann convention: docs/prd.md"

check_and_propose "doc/prd.md" "$canonical_prd" \
  "prd" 0.9 "doc/ (singular) → nyann convention: docs/"

check_and_propose "docs/product-requirements.md" "$canonical_prd" \
  "prd" 0.85 "docs/product-requirements.md → nyann convention: docs/prd.md"

# --- ADR patterns ------------------------------------------------------------

check_and_propose "adr" "$canonical_adrs" \
  "adrs" 0.9 "adr/ → nyann convention: docs/decisions/"

check_and_propose "adrs" "$canonical_adrs" \
  "adrs" 0.9 "adrs/ → nyann convention: docs/decisions/"

check_and_propose "ADR" "$canonical_adrs" \
  "adrs" 0.9 "ADR/ → nyann convention: docs/decisions/"

check_and_propose "docs/adr" "$canonical_adrs" \
  "adrs" 0.9 "docs/adr/ → nyann convention: docs/decisions/"

check_and_propose "docs/adrs" "$canonical_adrs" \
  "adrs" 0.85 "docs/adrs/ → nyann convention: docs/decisions/"

check_and_propose "decisions" "$canonical_adrs" \
  "adrs" 0.85 "Root-level decisions/ → nyann convention: docs/decisions/"

check_and_propose "doc/decisions" "$canonical_adrs" \
  "adrs" 0.85 "doc/decisions/ → nyann convention: docs/decisions/"

# --- Research patterns -------------------------------------------------------

check_and_propose "research" "$canonical_research" \
  "research" 0.9 "Root-level research/ → nyann convention: docs/research/"

check_and_propose "docs/notes" "$canonical_research" \
  "research" 0.6 "docs/notes/ may contain research material"

check_and_propose "docs/spikes" "$canonical_research" \
  "research" 0.7 "docs/spikes/ → nyann convention: docs/research/"

check_and_propose "doc/research" "$canonical_research" \
  "research" 0.85 "doc/ (singular) → nyann convention: docs/"

# --- API reference patterns --------------------------------------------------

check_and_propose "API.md" "$canonical_api_reference" \
  "api_reference" 0.85 "Root-level API.md → nyann convention: docs/api-reference.md"

check_and_propose "api.md" "$canonical_api_reference" \
  "api_reference" 0.85 "Root-level api.md → nyann convention: docs/api-reference.md"

check_and_propose "docs/api.md" "$canonical_api_reference" \
  "api_reference" 0.9 "docs/api.md → nyann convention: docs/api-reference.md"

check_and_propose "docs/API.md" "$canonical_api_reference" \
  "api_reference" 0.9 "docs/API.md → nyann convention: docs/api-reference.md"

check_and_propose "docs/endpoints.md" "$canonical_api_reference" \
  "api_reference" 0.75 "docs/endpoints.md → nyann convention: docs/api-reference.md"

# --- Runbook patterns --------------------------------------------------------

check_and_propose "RUNBOOK.md" "$canonical_runbook" \
  "runbook" 0.95 "Root-level RUNBOOK.md → nyann convention: docs/runbook.md"

check_and_propose "runbook.md" "$canonical_runbook" \
  "runbook" 0.95 "Root-level runbook.md → nyann convention: docs/runbook.md"

check_and_propose "docs/operations.md" "$canonical_runbook" \
  "runbook" 0.75 "docs/operations.md → nyann convention: docs/runbook.md"

check_and_propose "docs/ops.md" "$canonical_runbook" \
  "runbook" 0.7 "docs/ops.md → nyann convention: docs/runbook.md"

check_and_propose "docs/playbook.md" "$canonical_runbook" \
  "runbook" 0.8 "docs/playbook.md → nyann convention: docs/runbook.md"

# --- Deployment patterns -----------------------------------------------------

check_and_propose "DEPLOYMENT.md" "$canonical_deployment" \
  "deployment" 0.95 "Root-level DEPLOYMENT.md → nyann convention: docs/deployment.md"

check_and_propose "deployment.md" "$canonical_deployment" \
  "deployment" 0.9 "Root-level deployment.md → nyann convention: docs/deployment.md"

check_and_propose "docs/deploy.md" "$canonical_deployment" \
  "deployment" 0.85 "docs/deploy.md → nyann convention: docs/deployment.md"

check_and_propose "docs/DEPLOY.md" "$canonical_deployment" \
  "deployment" 0.85 "docs/DEPLOY.md → nyann convention: docs/deployment.md"

check_and_propose "docs/hosting.md" "$canonical_deployment" \
  "deployment" 0.65 "docs/hosting.md may describe deployment"

# --- Glossary patterns -------------------------------------------------------

check_and_propose "GLOSSARY.md" "$canonical_glossary" \
  "glossary" 0.95 "Root-level GLOSSARY.md → nyann convention: docs/glossary.md"

check_and_propose "glossary.md" "$canonical_glossary" \
  "glossary" 0.9 "Root-level glossary.md → nyann convention: docs/glossary.md"

check_and_propose "docs/terms.md" "$canonical_glossary" \
  "glossary" 0.75 "docs/terms.md → nyann convention: docs/glossary.md"

check_and_propose "docs/terminology.md" "$canonical_glossary" \
  "glossary" 0.8 "docs/terminology.md → nyann convention: docs/glossary.md"

check_and_propose "docs/definitions.md" "$canonical_glossary" \
  "glossary" 0.7 "docs/definitions.md → nyann convention: docs/glossary.md"

# --- Dedup: keep highest-confidence proposal per target ----------------------
# On case-insensitive filesystems (macOS default), ARCHITECTURE.md and
# architecture.md resolve to the same file. Multiple patterns may match
# the same underlying file, producing duplicate proposals for one target.

proposals=$(jq '
  group_by(.target)
  | map(sort_by(-.confidence) | .[0])
  | sort_by(-.confidence)
' <<<"$proposals")

# --- Output ------------------------------------------------------------------

count=$(jq 'length' <<<"$proposals")
if (( count > 0 )); then
  nyann::log "found $count non-conforming doc(s) that can be reorganized"
fi

jq '.' <<<"$proposals"
