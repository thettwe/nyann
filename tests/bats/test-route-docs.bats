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

# v1.6.0 — --archetype CLI flag enum guard. The profile schema validates
# archetype values at load time, but the CLI flag bypasses that path.
# Without explicit guard a typo silently produced an under-populated
# DocumentationPlan via nyann::archetype_scaffold_map's `*` fallback.
@test "--archetype with valid enum value succeeds" {
  for a in api-service cli-tool library web-app mobile-app plugin unknown; do
    run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" --archetype "$a"
    [ "$status" -eq 0 ]
  done
}

@test "--archetype with invalid value dies with clear error" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" --archetype "future-arch"
  [ "$status" -eq 1 ]
  [[ "$output" == *"future-arch"* ]]
  [[ "$output" == *"is not one of"* ]]
}

@test "--archetype with shell-injection-style value is rejected (not executed)" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" --archetype 'evil; rm -rf /tmp/x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not one of"* ]]
}

# v1.6.0 robustness — non-boolean use_archetype_scaffolds coerced to false
# with a warning rather than dying mid-emit on jq --argjson parse error.
# The profile schema rejects this case at load time, but the defensive
# coercion guards against bypassed validation paths.
@test "non-boolean use_archetype_scaffolds in profile is coerced to false" {
  # Hand-craft a profile that passes top-level shape but has the wrong
  # type for the v1.6.0 boolean field. Schema validation isn't invoked
  # by route-docs directly (load-profile.sh does that upstream), so a
  # bypassed-validation scenario hits this path.
  cat > "$TMP/bad-profile.json" <<'JSON'
{
  "name": "bad-bool",
  "schemaVersion": 1,
  "stack": {"primary_language": "unknown"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "conventions": {"commit_format": "conventional-commits"},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": false, "editorconfig": false, "claude_md": false, "github_actions_ci": false, "commit_message_template": false, "github_templates": false},
  "documentation": {
    "scaffold_types": [],
    "storage_strategy": "local",
    "preferred_mcp": null,
    "adr_format": "madr",
    "claude_md_mode": "router",
    "claude_md_size_budget_kb": 3,
    "staleness_days": null,
    "enable_drift_checks": {"broken_internal_links": false, "broken_mcp_links": false, "orphans": false, "staleness": false},
    "use_archetype_scaffolds": "yes"
  }
}
JSON
  run bash "$ROUTE" --profile "$TMP/bad-profile.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a boolean"* ]] || [[ "$stderr" == *"is not a boolean"* ]]
  # Output is still valid JSON
  echo "$output" | grep -v "coercing" | jq -e '.targets' >/dev/null
}

# Obsidian URL space encoding — vault names / folder paths with spaces
# must percent-encode to %20 in the link_in_claude_md field. Bare
# spaces terminate the URL in many Markdown parsers.
@test "obsidian link_in_claude_md percent-encodes spaces in vault name" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.obs.json" --routing all:obsidian \
    --obsidian-vault "My Vault" --project-name myproj
  [ "$status" -eq 0 ]
  link=$(echo "$output" | jq -r '.targets.architecture.link_in_claude_md')
  # Encoded link must NOT contain a literal space and MUST contain %20
  [[ "$link" != *" "* ]]
  [[ "$link" == *"My%20Vault"* ]]
  # The raw vault field stays unchanged for downstream MCP tooling
  [ "$(echo "$output" | jq -r '.targets.architecture.vault')" = "My Vault" ]
}

@test "obsidian link_in_claude_md percent-encodes spaces in folder path" {
  run bash "$ROUTE" --profile "$PROFILES/nextjs-prototype.json" \
    --mcp-targets "$TMP/.obs.json" --routing all:obsidian \
    --obsidian-vault work --obsidian-folder "team docs" \
    --project-name "my project"
  [ "$status" -eq 0 ]
  link=$(echo "$output" | jq -r '.targets.architecture.link_in_claude_md')
  [[ "$link" != *" "* ]]
  [[ "$link" == *"team%20docs"* ]]
  [[ "$link" == *"my%20project"* ]]
}
