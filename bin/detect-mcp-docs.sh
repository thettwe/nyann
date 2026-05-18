#!/usr/bin/env bash
# detect-mcp-docs.sh — classify user's Claude Code MCP servers against
# the doc-tool registry and discover local Obsidian vaults.
#
# Usage:
#   detect-mcp-docs.sh [--settings-path <path>] [--project-path <dir>]
#                      [--registry <path>]
#
# Reads Claude Code settings from multiple sources (global + project-level)
# and emits an MCPDocTargets JSON. Also discovers local Obsidian vaults
# that could be connected. Read-only — never invokes MCP tools.
#
# An MCP server entry is:
#   - `available`               — name matches a registry connector and is enabled
#                                 (or `enabled` is absent → treated as enabled).
#   - `configured_but_disabled` — name matches but the entry declares `enabled:false`.
#   - `unknown_servers_skipped` — name doesn't match any registered connector.
#
# A `discoverable_vaults` entry is an Obsidian vault found on disk but not
# connected via MCP — the skill layer can offer to connect these.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

settings_path="${HOME}/.claude/settings.json"
project_path=""
registry_path="${_script_dir}/../templates/mcp-registry.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings-path)    settings_path="${2:-}"; shift 2 ;;
    --settings-path=*)  settings_path="${1#--settings-path=}"; shift ;;
    --project-path)     project_path="${2:-}"; shift 2 ;;
    --project-path=*)   project_path="${1#--project-path=}"; shift ;;
    --registry)         registry_path="${2:-}"; shift 2 ;;
    --registry=*)       registry_path="${1#--registry=}"; shift ;;
    -h|--help)          sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -f "$registry_path" ]] || nyann::die "registry not found: $registry_path"

# Build list of settings files to check. Project-level settings can
# also declare mcpServers (Claude Code merges them at runtime).
# Order is lowest-to-highest precedence — later entries override earlier
# during the merge below. Convention (matching Claude Code itself):
#   global ~/.claude/settings.json
#   < project .claude/settings.json (checked in)
#   < project .claude/settings.local.json (user-local, typically gitignored)
# settings.local.json MUST win so a user can disable / repoint a server
# without rewriting the committed project file.
settings_sources=()
[[ -f "$settings_path" ]] && settings_sources+=("$settings_path")

if [[ -n "$project_path" ]]; then
  project_settings="$project_path/.claude/settings.json"
  [[ -f "$project_settings" ]] && settings_sources+=("$project_settings")
  local_settings="$project_path/.claude/settings.local.json"
  [[ -f "$local_settings" ]] && settings_sources+=("$local_settings")
fi

# If no settings files exist at all, emit an empty report.
if (( ${#settings_sources[@]} == 0 )); then
  jq -n --arg p "$settings_path" '{
    settings_path: $p,
    settings_sources: [],
    available: [],
    configured_but_disabled: [],
    unknown_servers_skipped: [],
    discoverable_vaults: []
  }'
  exit 0
fi

# Validate the primary settings file is parseable JSON.
if [[ -f "$settings_path" ]]; then
  jq empty "$settings_path" 2>/dev/null \
    || nyann::die "failed to parse $settings_path as JSON"
fi

# Merge mcpServers from all settings sources into one flat object.
# Later sources override earlier ones: settings.local.json > project
# settings.json > global ~/.claude/settings.json. Order set above.
servers_json='{}'
for src in "${settings_sources[@]}"; do
  src_servers=$(jq '(.mcpServers // .mcp_servers // {})' "$src" 2>/dev/null) || continue
  servers_json=$(jq -s '.[0] * .[1]' <<<"$servers_json"$'\n'"$src_servers")
done

# --- Obsidian vault discovery ------------------------------------------------
# Look for .obsidian directories under --project-path. Scoped strictly to
# the project tree so bootstrap never enumerates a user's home directory:
# scanning $HOME/Documents leaked personal vault paths into bootstrap
# output (and from there into boot records / drift reports / committed
# artifacts) without the operator's consent. The discovery is now a
# project-only feature — vaults under $HOME need to be wired in via a
# configured MCP server before nyann knows about them.
vault_search_paths=()
[[ -n "$project_path" && -d "$project_path" ]] && vault_search_paths+=("$project_path")
[[ -n "$project_path" && -d "$project_path/docs" ]] && vault_search_paths+=("$project_path/docs")

discovered_vaults_json='[]'
_seen_vault_paths=""
for search_dir in "${vault_search_paths[@]+"${vault_search_paths[@]}"}"; do
  while IFS= read -r obsidian_dir; do
    vault_root="$(dirname "$obsidian_dir")"
    vault_name="$(basename "$vault_root")"
    # Deduplicate by path
    case "$_seen_vault_paths" in
      *"|${vault_root}|"*) continue ;;
    esac
    _seen_vault_paths="${_seen_vault_paths}|${vault_root}|"
    discovered_vaults_json=$(jq --arg name "$vault_name" --arg path "$vault_root" \
      '. + [{"vault_name": $name, "vault_path": $path}]' <<<"$discovered_vaults_json")
  done < <(find "$search_dir" -maxdepth 3 -name ".obsidian" -type d 2>/dev/null)
done

# Graceful degrade when python3 is absent.
if ! nyann::has_cmd python3; then
  nyann::warn "python3 not found; MCP detection will report zero connectors"
  jq -n \
    --arg p "$settings_path" \
    --argjson sources "$(printf '%s\n' "${settings_sources[@]}" | jq -R . | jq -s .)" \
    --argjson vaults "$discovered_vaults_json" \
    '{
      settings_path: $p,
      settings_sources: $sources,
      available: [],
      configured_but_disabled: [],
      unknown_servers_skipped: [],
      discoverable_vaults: $vaults
    }'
  exit 0
fi

# Pass inputs to Python via env vars (avoids shell expansion issues).
sources_json=$(printf '%s\n' "${settings_sources[@]}" | jq -R . | jq -s .)

NYANN_MCP_SERVERS_JSON="$servers_json" \
NYANN_MCP_SETTINGS_PATH="$settings_path" \
NYANN_MCP_SETTINGS_SOURCES="$sources_json" \
NYANN_MCP_VAULTS="$discovered_vaults_json" \
python3 - "$registry_path" <<'PY'
import json, os, sys, fnmatch

registry = json.load(open(sys.argv[1]))
servers = json.loads(os.environ['NYANN_MCP_SERVERS_JSON'])
settings_path = os.environ['NYANN_MCP_SETTINGS_PATH']
settings_sources = json.loads(os.environ['NYANN_MCP_SETTINGS_SOURCES'])
discovered_vaults = json.loads(os.environ['NYANN_MCP_VAULTS'])

def classify(server_name, entry):
    enabled = entry.get('enabled', True) if isinstance(entry, dict) else True
    for conn in registry['connectors']:
        for pat in conn['name_patterns']:
            if fnmatch.fnmatch(server_name, pat) or server_name == pat:
                return conn, enabled
    return None, enabled

available = []
disabled = []
unknown = []

for name, entry in servers.items():
    conn, enabled = classify(name, entry)
    if conn is None:
        unknown.append(name)
        continue
    if not enabled:
        disabled.append({"type": conn['type'], "server_name": name})
        continue
    available.append({
        "type":         conn['type'],
        "server_name":  name,
        "uri_scheme":   conn['uri_scheme'],
        "capabilities": conn['required_tools'],
        "status":       "unknown"
    })

# If Obsidian MCP is already available, don't suggest discoverable vaults
has_obsidian_mcp = any(a['type'] == 'obsidian' for a in available)
if has_obsidian_mcp:
    discovered_vaults = []

print(json.dumps({
    "settings_path": settings_path,
    "settings_sources": settings_sources,
    "available": available,
    "configured_but_disabled": disabled,
    "unknown_servers_skipped": sorted(unknown),
    "discoverable_vaults": discovered_vaults
}, indent=2))
PY
