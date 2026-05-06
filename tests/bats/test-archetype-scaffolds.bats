#!/usr/bin/env bats
# v1.6.0 archetype-aware scaffolding: per-archetype doc sets land in
# the right files (api-service → architecture + api-reference +
# runbook + deployment + adrs + glossary, etc.).
#
# scaffold-docs.sh is a pure materializer — it iterates the targets[]
# its plan declares. The archetype expansion happens upstream in
# route-docs.sh (the planner). These tests use the realistic two-step
# flow: a tiny stub profile → route-docs → scaffold-docs.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCAFFOLD="${REPO_ROOT}/bin/scaffold-docs.sh"
  ROUTE="${REPO_ROOT}/bin/route-docs.sh"
  TMP=$(mktemp -d -t nyann-arch-scaffold.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Helper: write a minimal stub profile (the smallest schema-valid
# shape) and call route-docs to produce a fully-expanded
# DocumentationPlan with targets[] populated by the archetype map.
# scaffold-docs then iterates the resolved targets — matching the
# realistic skill → orchestrator → subsystem flow.
write_plan() {
  local archetype="$1" use_flag="$2" plan_path="$3"
  cat > "$TMP/.profile.json" <<PROFILE
{
  "name": "stub-test",
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
    "enable_drift_checks": {"broken_internal_links": false, "broken_mcp_links": false, "orphans": false, "staleness": false}
  }
}
PROFILE
  if [[ "$use_flag" == "true" ]]; then
    bash "$ROUTE" --profile "$TMP/.profile.json" --archetype "$archetype" --use-archetype-scaffolds > "$plan_path"
  else
    bash "$ROUTE" --profile "$TMP/.profile.json" --archetype "$archetype" --no-use-archetype-scaffolds > "$plan_path"
  fi
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

@test "scaffold-docs is a pure materializer — only iterates plan.targets[]" {
  # The plan declares architecture (local) and api_reference (obsidian)
  # explicitly, plus archetype + use_archetype_scaffolds for downstream
  # informational visibility. scaffold-docs MUST iterate only what's in
  # targets[] — it does NOT expand the archetype map at materialization
  # time (that violates preview-before-mutate against the SHA-bound
  # ActionPlan). Archetype expansion is route-docs.sh's job.
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
  # The other archetype types (runbook / deployment / glossary / adrs)
  # are NOT in targets[], so scaffold-docs does NOT write them.
  # Callers wanting the full archetype set must run route-docs first.
  [ ! -f "$TMP/docs/runbook.md" ]
  [ ! -f "$TMP/docs/deployment.md" ]
  [ ! -d "$TMP/docs/decisions" ]
  [ ! -f "$TMP/docs/glossary.md" ]
}

@test "scaffolding is idempotent — re-run does not overwrite user content" {
  write_plan "api-service" "true" "$TMP/.plan.json"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  echo "USER WROTE THIS" > "$TMP/docs/api-reference.md"
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  grep -q "USER WROTE THIS" "$TMP/docs/api-reference.md"
}

@test "doc README lands in architecture target's parent dir for custom paths" {
  # When the plan routes architecture to a custom path like
  # `wiki/architecture.md`, the doc README must follow it to
  # `wiki/README.md` instead of falling back to `docs/README.md`.
  cat > "$TMP/.plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "architecture": {"type": "local", "path": "wiki/architecture.md"},
    "adrs":         {"type": "local", "path": "wiki/decisions"}
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null
}
JSON
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  [ -f "$TMP/wiki/README.md" ]
  [ -f "$TMP/wiki/architecture.md" ]
  [ ! -f "$TMP/docs/README.md" ]
}

@test "doc README falls back to docs/ when architecture is non-local or absent" {
  # Pre-v1.6.x default behaviour: any local doc target triggers
  # docs/README.md. With architecture absent (only adrs scaffolded
  # at default paths), the README must still land in docs/.
  cat > "$TMP/.plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "adrs": {"type": "local", "path": "docs/decisions"}
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null
}
JSON
  bash "$SCAFFOLD" --plan "$TMP/.plan.json" --target "$TMP" --project-name svc >/dev/null 2>&1
  [ -f "$TMP/docs/README.md" ]
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
