#!/usr/bin/env bats
# v1.9.0: detect-mcp-docs.sh supports multi-source settings (global + project)
# and discoverable_vaults via --project-path.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MCP="${REPO_ROOT}/bin/detect-mcp-docs.sh"
  REG="${REPO_ROOT}/templates/mcp-registry.json"
  TMP="$(mktemp -d)"
  PROJ="$TMP/project"
  mkdir -p "$PROJ/.claude"
}

teardown() { rm -rf "$TMP"; }

# Helper: scope HOME to $TMP so the test machine's real $HOME/Documents
# Obsidian vaults don't pollute discoverable_vaults during the test.
mcp_run() {
  HOME="$TMP" bash "$MCP" "$@" 2>/dev/null
}

@test "empty settings + no project: emits skeleton with empty arrays" {
  echo '{}' > "$TMP/settings.json"
  json=$(mcp_run --settings-path "$TMP/settings.json" --registry "$REG")
  [ "$(echo "$json" | jq -r '.settings_path')" = "$TMP/settings.json" ]
  [ "$(echo "$json" | jq '.settings_sources | length')" -eq 1 ]
  [ "$(echo "$json" | jq '.available | length')" -eq 0 ]
  [ "$(echo "$json" | jq '.discoverable_vaults | length')" -eq 0 ]
}

@test "missing settings file: emits empty skeleton, settings_sources empty" {
  json=$(mcp_run --settings-path "$TMP/nonexistent.json" --registry "$REG")
  [ "$(echo "$json" | jq '.settings_sources | length')" -eq 0 ]
  [ "$(echo "$json" | jq '.available | length')" -eq 0 ]
}

@test "--project-path picks up project-level settings.json" {
  echo '{}' > "$TMP/settings.json"
  echo '{"mcpServers": {"obsidian-mcp": {"command": "fake"}}}' > "$PROJ/.claude/settings.json"
  json=$(mcp_run --settings-path "$TMP/settings.json" \
    --project-path "$PROJ" --registry "$REG")
  # Both sources should be listed
  [ "$(echo "$json" | jq '.settings_sources | length')" -eq 2 ]
  echo "$json" | jq -e '.settings_sources | any(. | test("settings.json$"))' >/dev/null
}

@test "--project-path picks up settings.local.json over .claude/settings.json" {
  echo '{}' > "$TMP/settings.json"
  echo '{"mcpServers": {"foo": {}}}' > "$PROJ/.claude/settings.local.json"
  json=$(mcp_run --settings-path "$TMP/settings.json" \
    --project-path "$PROJ" --registry "$REG")
  [ "$(echo "$json" | jq '.settings_sources | length')" -eq 2 ]
}

@test "discoverable_vaults: finds .obsidian/ under --project-path" {
  echo '{}' > "$TMP/settings.json"
  mkdir -p "$PROJ/my-vault/.obsidian"
  json=$(mcp_run --settings-path "$TMP/settings.json" \
    --project-path "$PROJ" --registry "$REG")
  # Vault should be discoverable since Obsidian MCP is NOT configured
  [ "$(echo "$json" | jq '.discoverable_vaults | length')" -ge 1 ]
  # Locate the my-vault entry rather than assuming index 0 (search order
  # may surface other vaults found via inherited search paths first).
  [ "$(echo "$json" | jq '[.discoverable_vaults[] | select(.vault_name == "my-vault")] | length')" -eq 1 ]
}

@test "discoverable_vaults are deduped by path" {
  echo '{}' > "$TMP/settings.json"
  mkdir -p "$PROJ/vault/.obsidian"
  mkdir -p "$PROJ/docs/vault/.obsidian"
  json=$(mcp_run --settings-path "$TMP/settings.json" \
    --project-path "$PROJ" --registry "$REG")
  count=$(echo "$json" | jq '.discoverable_vaults | length')
  [ "$count" -ge 1 ]
  unique=$(echo "$json" | jq '[.discoverable_vaults[].vault_path] | unique | length')
  [ "$count" -eq "$unique" ]
}

@test "malformed settings JSON dies with a clear error" {
  echo 'not-json' > "$TMP/settings.json"
  HOME="$TMP" run bash "$MCP" --settings-path "$TMP/settings.json" --registry "$REG"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "failed to parse"
}

@test "vaults outside --project-path are NOT discovered (privacy guard)" {
  # Regression guard: an earlier implementation auto-scanned $HOME/Documents
  # for .obsidian directories during every bootstrap. That leaked personal
  # vault paths from the user's home into the MCPDocTargets JSON (and from
  # there into boot records / drift reports / committed artifacts). The
  # scan is now strictly scoped to --project-path.
  echo '{}' > "$TMP/settings.json"

  # Stage a fake home with a vault that MUST NOT be reported.
  fake_home="$TMP/home"
  mkdir -p "$fake_home/Documents/SecretVault/.obsidian"

  # Project path has nothing under it.
  mkdir -p "$PROJ"

  json=$(HOME="$fake_home" bash "$MCP" \
    --settings-path "$TMP/settings.json" \
    --project-path "$PROJ" --registry "$REG" 2>/dev/null)

  # Discovery is empty: the home vault must be invisible.
  [ "$(echo "$json" | jq '.discoverable_vaults | length')" -eq 0 ]
  # Defensive: also assert no vault path containing the fake home leaked.
  echo "$json" | jq -e '[.discoverable_vaults[]?.vault_path | select(. | contains("SecretVault"))] | length == 0' >/dev/null
}

@test "precedence: settings.local.json wins over project settings.json (regression)" {
  # Codex adversarial review high #1: a user-local override (settings.local.json,
  # typically gitignored) MUST beat the checked-in project file. Otherwise a repo
  # can silently override a developer's local disable/repoint.
  echo '{}' > "$TMP/settings.json"
  # Committed project file: server enabled.
  cat > "$PROJ/.claude/settings.json" <<'EOF'
{"mcpServers": {"obsidian-mcp": {"command": "checked-in-cmd", "enabled": true}}}
EOF
  # User-local override: same server, DISABLED.
  cat > "$PROJ/.claude/settings.local.json" <<'EOF'
{"mcpServers": {"obsidian-mcp": {"command": "local-cmd", "enabled": false}}}
EOF

  json=$(HOME="$TMP" bash "$MCP" --settings-path "$TMP/settings.json" \
    --project-path "$PROJ" --registry "$REG" 2>/dev/null)

  # Both sources should appear in settings_sources[].
  [ "$(echo "$json" | jq '.settings_sources | length')" -eq 3 ]

  # The local file disabled the server → must land in configured_but_disabled,
  # NOT available. If precedence is wrong, the committed enabled:true wins and
  # obsidian-mcp shows up in available[] instead.
  available_count=$(echo "$json" | jq '[.available[] | select(.server_name == "obsidian-mcp")] | length')
  disabled_count=$(echo "$json" | jq '[.configured_but_disabled[] | select(.server_name == "obsidian-mcp")] | length')
  [ "$available_count" -eq 0 ]
  [ "$disabled_count" -eq 1 ]
}
