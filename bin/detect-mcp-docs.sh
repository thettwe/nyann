#!/usr/bin/env bash
# detect-mcp-docs.sh — classify user's Claude Code MCP servers against
# the doc-tool registry.
#
# Usage:
#   detect-mcp-docs.sh [--settings-path <path>] [--registry <path>]
#
# Reads Claude Code settings (default: ~/.claude/settings.json) and
# emits an MCPDocTargets JSON. Read-only — never invokes MCP tools.
#
# An MCP server entry is:
#   - `available`               — name matches a registry connector and is enabled
#                                 (or `enabled` is absent → treated as enabled).
#   - `configured_but_disabled` — name matches but the entry declares `enabled:false`.
#   - `unknown_servers_skipped` — name doesn't match any registered connector.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

settings_path="${HOME}/.claude/settings.json"
registry_path="${_script_dir}/../templates/mcp-registry.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings-path)    settings_path="${2:-}"; shift 2 ;;
    --settings-path=*)  settings_path="${1#--settings-path=}"; shift ;;
    --registry)         registry_path="${2:-}"; shift 2 ;;
    --registry=*)       registry_path="${1#--registry=}"; shift ;;
    -h|--help)          sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -f "$registry_path" ]] || nyann::die "registry not found: $registry_path"

# Settings may legitimately be absent (user has no MCPs configured yet).
# Emit an empty report rather than erroring.
if [[ ! -f "$settings_path" ]]; then
  jq -n --arg p "$settings_path" '{
    settings_path: $p,
    available: [],
    configured_but_disabled: [],
    unknown_servers_skipped: []
  }'
  exit 0
fi

# Merge all mcpServers into a flat object we can iterate.
# Tolerate either .mcpServers or .mcp_servers spellings.
servers_json=$(jq '(.mcpServers // .mcp_servers // {})' "$settings_path") \
  || nyann::die "failed to parse $settings_path as JSON"

# Graceful degrade when python3 is absent: emit an empty report so the
# rest of the bootstrap / doctor flow treats the machine as "no known
# MCP connectors available" rather than crashing.
if ! nyann::has_cmd python3; then
  nyann::warn "python3 not found; MCP detection will report zero connectors"
  jq -n --arg p "$settings_path" '{
    settings_path: $p,
    available: [],
    configured_but_disabled: [],
    unknown_servers_skipped: []
  }'
  exit 0
fi

# Pass untrusted inputs (servers_json from settings.json, settings_path
# which may contain arbitrary characters) via env vars + argv so they
# never flow through shell expansion inside the heredoc. The heredoc
# delimiter is quoted ('PY') to disable expansion entirely.
NYANN_MCP_SERVERS_JSON="$servers_json" \
NYANN_MCP_SETTINGS_PATH="$settings_path" \
python3 - "$registry_path" <<'PY'
import json, os, sys, fnmatch

registry = json.load(open(sys.argv[1]))
servers = json.loads(os.environ['NYANN_MCP_SERVERS_JSON'])
settings_path = os.environ['NYANN_MCP_SETTINGS_PATH']

def classify(server_name, entry):
    enabled = entry.get('enabled', True) if isinstance(entry, dict) else True
    for conn in registry['connectors']:
        for pat in conn['name_patterns']:
            # Support glob-style patterns; most are literal strings.
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

print(json.dumps({
    "settings_path": settings_path,
    "available": available,
    "configured_but_disabled": disabled,
    "unknown_servers_skipped": sorted(unknown)
}, indent=2))
PY
