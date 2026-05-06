#!/usr/bin/env bats
# v1.6.0 archetype-aware scaffolding: when DocumentationPlan declares
# use_archetype_scaffolds:true and an archetype, scaffold-docs.sh
# materializes the per-archetype doc set (api-service → architecture +
# api-reference + runbook + deployment + adrs + glossary, etc.).
#
# When use_archetype_scaffolds is false or absent (default),
# pre-v1.6.0 behavior is preserved — only targets[] entries already
# present in the plan get scaffolded.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCAFFOLD="${REPO_ROOT}/bin/scaffold-docs.sh"
  TMP=$(mktemp -d -t nyann-arch-scaffold.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Helper: write a minimal DocumentationPlan with the given archetype +
# use_archetype_scaffolds flag. Empty `targets:{}` so the archetype
# expansion is the sole driver.
write_plan() {
  local archetype="$1" use_flag="$2" plan_path="$3"
  cat > "$plan_path" <<JSON
{
  "storage_strategy": "local",
  "targets": {},
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null,
  "archetype": "${archetype}",
  "use_archetype_scaffolds": ${use_flag}
}
JSON
}

@test "api-service archetype scaffolds architecture, api-reference, runbook, deployment, adrs, glossary" {
  write_plan "api-service" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  [ -f "$TMP/docs/architecture.md" ]
  [ -f "$TMP/docs/api-reference.md" ]
  [ -f "$TMP/docs/runbook.md" ]
  [ -f "$TMP/docs/deployment.md" ]
  [ -d "$TMP/docs/decisions" ]
  [ -f "$TMP/docs/glossary.md" ]
  # PRD and research NOT in api-service map.
  [ ! -f "$TMP/docs/prd.md" ]
}

@test "cli-tool archetype scaffolds architecture, runbook, adrs, glossary (no api-reference)" {
  write_plan "cli-tool" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name cli >/dev/null 2>&1
  [ -f "$TMP/docs/architecture.md" ]
  [ -f "$TMP/docs/runbook.md" ]
  [ -d "$TMP/docs/decisions" ]
  [ -f "$TMP/docs/glossary.md" ]
  [ ! -f "$TMP/docs/api-reference.md" ]
  [ ! -f "$TMP/docs/deployment.md" ]
}

@test "library archetype scaffolds architecture, api-reference, adrs, glossary (no runbook)" {
  write_plan "library" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name lib >/dev/null 2>&1
  [ -f "$TMP/docs/architecture.md" ]
  [ -f "$TMP/docs/api-reference.md" ]
  [ -d "$TMP/docs/decisions" ]
  [ -f "$TMP/docs/glossary.md" ]
  [ ! -f "$TMP/docs/runbook.md" ]
  [ ! -f "$TMP/docs/deployment.md" ]
}

@test "web-app archetype scaffolds architecture, runbook, deployment, adrs, glossary" {
  write_plan "web-app" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name app >/dev/null 2>&1
  [ -f "$TMP/docs/architecture.md" ]
  [ -f "$TMP/docs/runbook.md" ]
  [ -f "$TMP/docs/deployment.md" ]
  [ -d "$TMP/docs/decisions" ]
  [ -f "$TMP/docs/glossary.md" ]
}

@test "plugin archetype scaffolds architecture, adrs, glossary (no runbook, no deployment)" {
  write_plan "plugin" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name plug >/dev/null 2>&1
  [ -f "$TMP/docs/architecture.md" ]
  [ -d "$TMP/docs/decisions" ]
  [ -f "$TMP/docs/glossary.md" ]
  [ ! -f "$TMP/docs/runbook.md" ]
  [ ! -f "$TMP/docs/deployment.md" ]
  [ ! -f "$TMP/docs/api-reference.md" ]
}

@test "use_archetype_scaffolds:false preserves pre-v1.6.0 behavior (empty targets → nothing scaffolded)" {
  write_plan "api-service" "false" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  # When the flag is false and targets is empty, no docs are scaffolded.
  [ ! -f "$TMP/docs/architecture.md" ]
  [ ! -f "$TMP/docs/api-reference.md" ]
  [ ! -f "$TMP/docs/runbook.md" ]
}

@test "explicit targets[] entries override archetype map (route-docs override path)" {
  cat > "$TMP/.plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "architecture": {"type": "local", "path": "docs/architecture.md"},
    "api_reference": {"type": "obsidian", "vault": "myvault"}
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null,
  "archetype": "api-service",
  "use_archetype_scaffolds": true
}
JSON
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc 2>/dev/null
  # architecture is local → file exists.
  [ -f "$TMP/docs/architecture.md" ]
  # api_reference is obsidian → no local file written for it.
  [ ! -f "$TMP/docs/api-reference.md" ]
  # runbook / deployment / adrs / glossary still get materialized as local
  # because the archetype map's defaults filled them in.
  [ -f "$TMP/docs/runbook.md" ]
  [ -f "$TMP/docs/deployment.md" ]
  [ -d "$TMP/docs/decisions" ]
  [ -f "$TMP/docs/glossary.md" ]
}

@test "scaffolding is idempotent — re-run does not overwrite user content" {
  write_plan "api-service" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  echo "USER WROTE THIS" > "$TMP/docs/api-reference.md"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  grep -q "USER WROTE THIS" "$TMP/docs/api-reference.md"
}

@test "robustness: plan with targets:null tolerates the missing object" {
  # Hand-crafted plan with .targets explicitly null — must not fail
  # silently via process-substitution swallow. Should succeed with
  # zero scaffolds and zero MCP-skip warnings.
  cat > "$TMP/.plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": null,
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null
}
JSON
  run bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/docs" ]
}

@test "robustness: plan with targets field omitted entirely tolerates the gap" {
  cat > "$TMP/.plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null
}
JSON
  run bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/docs" ]
}

@test "unknown archetype skips archetype expansion entirely (sentinel semantics)" {
  # archetype="unknown" is the sentinel for "no archetype declared".
  # use_archetype_scaffolds:true + archetype:"unknown" is a contradictory
  # combination — opt-in is on but no archetype was identified. The
  # expected behaviour is: skip the archetype path, leaving the plan's
  # targets[] alone (in this fixture, empty → nothing scaffolded). This
  # avoids silent fallback writes that would surprise users who
  # explicitly opted in expecting a real archetype to drive scaffolding.
  write_plan "unknown" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  [ ! -f "$TMP/docs/architecture.md" ]
  [ ! -d "$TMP/docs/decisions" ]
  [ ! -f "$TMP/docs/api-reference.md" ]
  [ ! -f "$TMP/docs/runbook.md" ]
  [ ! -f "$TMP/docs/glossary.md" ]
}
