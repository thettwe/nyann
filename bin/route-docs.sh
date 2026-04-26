#!/usr/bin/env bash
# route-docs.sh — produce a DocumentationPlan for the scaffolder.
#
# Usage:
#   route-docs.sh --profile <profile.json>
#                 [--mcp-targets <json>]
#                 [--routing <spec>]
#                 [--obsidian-vault <name>]
#                 [--obsidian-folder <path>]
#                 [--notion-parent <id-or-url>]
#                 [--project-name <name>]
#
# Behavior by --routing:
#   (absent) / 'all:local'    — every target local (default behavior)
#   'all:obsidian'            — every non-memory target obsidian, memory local
#   'all:notion'              — every non-memory target notion, memory local
#   'prd:notion,adrs:obsidian,research:local,architecture:local'
#                             — per-doc-type split; unmentioned keys fall
#                               back to local.
#
# `memory` is always local regardless of routing.
# storage_strategy is computed from the resulting target set:
#   local only   → "local"
#   all one MCP  → "obsidian" / "notion"
#   mixed        → "split"

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

profile_path=""
mcp_targets_json='{}'
routing_spec=""
obsidian_vault=""
obsidian_folder=""
notion_parent=""
project_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)          profile_path="${2:-}"; shift 2 ;;
    --profile=*)        profile_path="${1#--profile=}"; shift ;;
    --mcp-targets)      mcp_targets_json="$(cat "${2:-}")"; shift 2 ;;
    --mcp-targets=*)    mcp_targets_json="$(cat "${1#--mcp-targets=}")"; shift ;;
    --routing)          routing_spec="${2:-}"; shift 2 ;;
    --routing=*)        routing_spec="${1#--routing=}"; shift ;;
    --obsidian-vault)   obsidian_vault="${2:-}"; shift 2 ;;
    --obsidian-vault=*) obsidian_vault="${1#--obsidian-vault=}"; shift ;;
    --obsidian-folder)  obsidian_folder="${2:-}"; shift 2 ;;
    --obsidian-folder=*) obsidian_folder="${1#--obsidian-folder=}"; shift ;;
    --notion-parent)    notion_parent="${2:-}"; shift 2 ;;
    --notion-parent=*)  notion_parent="${1#--notion-parent=}"; shift ;;
    --project-name)     project_name="${2:-}"; shift 2 ;;
    --project-name=*)   project_name="${1#--project-name=}"; shift ;;
    -h|--help)          sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$profile_path" ]] || nyann::die "--profile is required"
[[ -f "$profile_path" ]] || nyann::die "profile not found: $profile_path"

# --- pull doc config from profile -------------------------------------------

profile_json="$(cat "$profile_path")"
doc_json="$(jq '.documentation' <<<"$profile_json")"
[[ "$doc_json" == "null" ]] && nyann::die "profile missing .documentation block"

scaffold_types_json="$(jq '.scaffold_types // []' <<<"$doc_json")"
claude_md_mode="$(jq -r '.claude_md_mode // "router"' <<<"$doc_json")"
size_budget_kb="$(jq '.claude_md_size_budget_kb // 3' <<<"$doc_json")"
staleness_days="$(jq '.staleness_days // null' <<<"$doc_json")"
[[ -z "$project_name" ]] && project_name=$(jq -r '.name // "project"' <<<"$profile_json")

# --- per-type path catalog --------------------------------------------------

declare_paths='{
  "architecture": "docs/architecture.md",
  "prd":          "docs/prd.md",
  "adrs":         "docs/decisions",
  "research":     "docs/research",
  "memory":       "memory"
}'

# --- parse routing spec -----------------------------------------------------
# Produces a per-type chosen backend map: {architecture:"local", prd:"notion", ...}

backend_for_type() {
  # $1 = doc type (architecture/prd/adrs/research/memory)
  # stdout: the chosen backend (local / obsidian / notion)
  local t="$1"
  if [[ "$t" == "memory" ]]; then
    echo "local"; return
  fi
  local spec="$routing_spec"
  [[ -z "$spec" ]] && { echo "local"; return; }
  # Split on commas.
  IFS=',' read -ra parts <<<"$spec"
  for p in "${parts[@]}"; do
    p="${p// /}"
    case "$p" in
      all:local|all:obsidian|all:notion)
        echo "${p#all:}"; return
        ;;
      "$t":local|"$t":obsidian|"$t":notion)
        echo "${p#*:}"; return
        ;;
    esac
  done
  # Per-type entry absent from a split spec → default local.
  echo "local"
}

# --- validation: any chosen MCP backend must be in available -----------------

available_types=$(jq -r '[.available[].type] | join(",")' <<<"$mcp_targets_json" 2>/dev/null || echo "")

validate_mcp_choice() {
  local t="$1" backend="$2"
  case "$backend" in
    obsidian|notion)
      if [[ ",$available_types," != *",$backend,"* ]]; then
        nyann::die "routing spec wants $t → $backend, but $backend is not in --mcp-targets.available"
      fi
      # And the skill layer should have supplied the vault / parent.
      if [[ "$backend" == "obsidian" ]] && [[ -z "$obsidian_vault" ]]; then
        nyann::die "routing $t to obsidian requires --obsidian-vault"
      fi
      if [[ "$backend" == "notion" ]] && [[ -z "$notion_parent" ]]; then
        nyann::die "routing $t to notion requires --notion-parent"
      fi
      ;;
  esac
}

# --- build targets ----------------------------------------------------------

targets_json='{}'

emit_target() {
  # $1=doc_type $2=backend
  local t="$1" backend="$2"
  local local_path
  local_path=$(jq -r --arg t "$t" '.[$t] // ""' <<<"$declare_paths")
  case "$backend" in
    local)
      [[ -z "$local_path" ]] && return
      targets_json=$(jq --arg t "$t" --arg p "$local_path" '. + {($t): {"type":"local","path":$p}}' <<<"$targets_json")
      ;;
    obsidian)
      # Folder convention: <obsidian_folder>/<doc-type-friendly-name>
      local folder_path link_base leaf
      case "$t" in
        architecture) leaf="architecture" ;;
        prd)          leaf="prd" ;;
        adrs)         leaf="decisions" ;;
        research)     leaf="research" ;;
      esac
      folder_path="${obsidian_folder:+${obsidian_folder}/}${project_name}/${leaf}"
      link_base="obsidian://vault/${obsidian_vault}/${folder_path}"
      targets_json=$(jq --arg t "$t" --arg vault "$obsidian_vault" --arg folder "$folder_path" --arg link "$link_base" '
        . + { ($t): { "type":"obsidian", "vault":$vault, "folder":$folder, "link_in_claude_md":$link } }
      ' <<<"$targets_json")
      ;;
    notion)
      targets_json=$(jq --arg t "$t" --arg parent "$notion_parent" '
        . + { ($t): { "type":"notion", "page_id":$parent, "link_in_claude_md":("notion://page/"+$parent) } }
      ' <<<"$targets_json")
      ;;
  esac
}

# Iterate profile-declared scaffold types.
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  backend=$(backend_for_type "$t")
  validate_mcp_choice "$t" "$backend"
  emit_target "$t" "$backend"
done < <(jq -r '.[]' <<<"$scaffold_types_json")

# memory: always local, regardless of spec.
emit_target "memory" "local"

# --- storage_strategy -------------------------------------------------------
# local only        → "local"
# all one MCP       → that MCP type
# mixed / split     → "split"
#
# `memory` is forced local by invariant a few lines up — counting it
# in the unique-types tally would make every all:obsidian or all:notion
# spec resolve as `split`, which is wrong. Exclude it from the tally
# so the all-MCP states remain reachable.

unique_types=$(jq -r '[to_entries[] | select(.key != "memory") | .value.type] | unique | join(",")' <<<"$targets_json")
case "$unique_types" in
  local)          storage_strategy="local" ;;
  obsidian,local) storage_strategy="split" ;;
  local,obsidian) storage_strategy="split" ;;
  notion,local)   storage_strategy="split" ;;
  local,notion)   storage_strategy="split" ;;
  *,*)            storage_strategy="split" ;;
  obsidian)       storage_strategy="obsidian" ;;
  notion)         storage_strategy="notion" ;;
  *)              storage_strategy="local" ;;
esac

# --- emit -------------------------------------------------------------------

jq -n \
  --arg storage_strategy "$storage_strategy" \
  --argjson targets "$targets_json" \
  --arg claude_md_mode "$claude_md_mode" \
  --argjson size_budget_kb "$size_budget_kb" \
  --argjson staleness_days "$staleness_days" \
  '{
    storage_strategy: $storage_strategy,
    targets: $targets,
    claude_md_mode: $claude_md_mode,
    size_budget_kb: $size_budget_kb,
    staleness_days: $staleness_days
  }'
