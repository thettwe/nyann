#!/usr/bin/env bats
# bin/detect-mcp-docs.sh across the mcp-configs fixture matrix.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-mcp-docs.sh"
  FIX="${REPO_ROOT}/tests/fixtures/mcp-configs"
}

@test "obsidian-available → available[].type == obsidian" {
  run bash "$DETECT" --settings-path "$FIX/obsidian-available.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.available[0].type')" = "obsidian" ]
  [ "$(echo "$output" | jq '.configured_but_disabled | length')" -eq 0 ]
}

@test "notion-available → available[].type == notion" {
  run bash "$DETECT" --settings-path "$FIX/notion-available.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.available[0].type')" = "notion" ]
}

@test "both-available → two entries" {
  run bash "$DETECT" --settings-path "$FIX/both-available.json"
  [ "$status" -eq 0 ]
  types=$(echo "$output" | jq -r '.available[].type' | sort | paste -sd, -)
  [ "$types" = "notion,obsidian" ]
}

@test "unknown-server → unknown_servers_skipped" {
  run bash "$DETECT" --settings-path "$FIX/unknown-server.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.available | length')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.unknown_servers_skipped[0]')" = "some-other-tool" ]
}

@test "obsidian-disabled → configured_but_disabled, not available" {
  run bash "$DETECT" --settings-path "$FIX/obsidian-disabled.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.available | length')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.configured_but_disabled[0].type')" = "obsidian" ]
}

@test "missing settings file → empty report, exit 0" {
  run bash "$DETECT" --settings-path /tmp/nonexistent-nyann-$$.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.available | length')" -eq 0 ]
}

@test "injection-safe: crafted server name/value does not execute shell/Python" {
  # Regression for heredoc-injection bug: shell-expanded $servers_json used
  # to sit inside '''...''' in a Python heredoc, so a crafted settings.json
  # could break out of the string literal. With env/argv passing this is
  # inert — the input comes through as a plain JSON key/value.
  tmp=$(mktemp -d)
  cat > "$tmp/settings.json" <<'JSON'
{
  "mcpServers": {
    "''' + __import__('os').system('touch /tmp/nyann-mcp-pwned-marker') + '''": {
      "command": "x"
    }
  }
}
JSON
  rm -f /tmp/nyann-mcp-pwned-marker
  run bash "$DETECT" --settings-path "$tmp/settings.json"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/nyann-mcp-pwned-marker ]
  # The crafted name is treated as an unknown server name, not code.
  [ "$(echo "$output" | jq '.unknown_servers_skipped | length')" -eq 1 ]
  rm -rf "$tmp"
}

@test "injection-safe: settings_path with quote is echoed verbatim, not evaluated" {
  # Regression: $settings_path was shell-interpolated into a Python string
  # at the bottom of the heredoc. A path containing a quote or backslash
  # would either break the JSON output or inject Python.
  tmp=$(mktemp -d)
  quirky="$tmp/with'quote.json"
  printf '{"mcpServers":{}}' > "$quirky"
  run bash "$DETECT" --settings-path "$quirky"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.settings_path')" = "$quirky" ]
  rm -rf "$tmp"
}

@test "malformed settings.json → fatal with clear error" {
  tmp=$(mktemp -d)
  printf '{not json' > "$tmp/settings.json"
  run bash "$DETECT" --settings-path "$tmp/settings.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "failed to parse"
  rm -rf "$tmp"
}

@test "output validates against MCPDocTargets schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "need uvx or check-jsonschema"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  for fix in obsidian-available notion-available both-available unknown-server obsidian-disabled; do
    tmp=$(mktemp)
    bash "$DETECT" --settings-path "$FIX/$fix.json" > "$tmp"
    run "${validator[@]}" --schemafile "${REPO_ROOT}/schemas/mcp-doc-targets.schema.json" "$tmp"
    [ "$status" -eq 0 ]
    rm -f "$tmp"
  done
}
