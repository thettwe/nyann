#!/usr/bin/env bats
# bin/route-docs.sh — local + MCP branches.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ROUTE="${REPO_ROOT}/bin/route-docs.sh"
  DETECT="${REPO_ROOT}/bin/detect-mcp-docs.sh"
  PROFILES="${REPO_ROOT}/profiles"
  SCHEMA="${REPO_ROOT}/schemas/documentation-plan.schema.json"
  TMP="$(mktemp -d)"
  bash "$DETECT" --settings-path "${REPO_ROOT}/tests/fixtures/mcp-configs/obsidian-available.json" > "$TMP/.obs.json"
  bash "$DETECT" --settings-path "${REPO_ROOT}/tests/fixtures/mcp-configs/both-available.json" > "$TMP/.both.json"
}

teardown() { rm -rf "$TMP"; }

@test "no MCPs → storage_strategy local" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.storage_strategy')" = "local" ]
  [ "$(echo "$output" | jq -r '.targets.memory.type')" = "local" ]
}

@test "all:obsidian with vault → obsidian targets + memory local + storage_strategy=obsidian" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.obs.json" --routing all:obsidian \
    --obsidian-vault work --project-name myproj
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.targets.memory.type')" = "local" ]
  [ "$(echo "$output" | jq -r '.targets.architecture.type')" = "obsidian" ]
  [ "$(echo "$output" | jq -r '.targets.prd.type')" = "obsidian" ]
  # The all-MCP states (`obsidian`, `notion`) are only reachable when
  # the storage_strategy tally excludes the always-local `memory`
  # target. Otherwise every all:obsidian / all:notion run silently
  # resolves to "split", which is wrong.
  [ "$(echo "$output" | jq -r '.storage_strategy')" = "obsidian" ]
}

@test "all:notion routing → storage_strategy=notion (memory excluded from tally)" {
  bash "$DETECT" --settings-path "${REPO_ROOT}/tests/fixtures/mcp-configs/both-available.json" > "$TMP/.both.json"
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.both.json" --routing all:notion \
    --notion-parent abc --project-name x
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.storage_strategy')" = "notion" ]
  [ "$(echo "$output" | jq -r '.targets.memory.type')" = "local" ]
}

@test "split routing → mixed target types" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.both.json" \
    --routing "prd:notion,adrs:obsidian,research:local,architecture:local" \
    --obsidian-vault v --obsidian-folder f --notion-parent p --project-name x
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.storage_strategy')" = "split" ]
  [ "$(echo "$output" | jq -r '.targets.prd.type')" = "notion" ]
  [ "$(echo "$output" | jq -r '.targets.adrs.type')" = "obsidian" ]
  [ "$(echo "$output" | jq -r '.targets.research.type')" = "local" ]
  [ "$(echo "$output" | jq -r '.targets.architecture.type')" = "local" ]
}

@test "routing to unavailable backend → exit non-zero" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.obs.json" --routing all:notion --notion-parent p \
    --project-name x
  [ "$status" -ne 0 ]
}

@test "memory target is always local regardless of routing" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.obs.json" --routing all:obsidian \
    --obsidian-vault work --project-name myproj
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.targets.memory.type')" = "local" ]
  [ "$(echo "$output" | jq -r '.targets.memory.path')" = "memory" ]
}

@test "output validates against DocumentationPlan schema across modes" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "need uvx or check-jsonschema"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  for m in "local" "all-obsidian" "split"; do
    out=$(mktemp)
    case "$m" in
      local) bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" > "$out" ;;
      all-obsidian) bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" --mcp-targets "$TMP/.obs.json" --routing all:obsidian --obsidian-vault work --project-name x > "$out" ;;
      split) bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" --mcp-targets "$TMP/.both.json" --routing "prd:notion,adrs:obsidian,research:local,architecture:local" --obsidian-vault v --obsidian-folder f --notion-parent p --project-name x > "$out" ;;
    esac
    run "${validator[@]}" --schemafile "$SCHEMA" "$out"
    [ "$status" -eq 0 ]
    rm -f "$out"
  done
}
