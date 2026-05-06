#!/usr/bin/env bats
# v1.6.0 templates: api-reference, runbook, deployment, glossary all
# render correctly via scaffold-docs.sh and follow Project Memory
# principles (predictable structure, cross-links to other docs).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCAFFOLD="${REPO_ROOT}/bin/scaffold-docs.sh"
  ROUTE="${REPO_ROOT}/bin/route-docs.sh"
  TMP=$(mktemp -d -t nyann-tmpl-arch.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  PLAN="$TMP/.plan.json"
}

teardown() { rm -rf "$TMP"; }

# scaffold-docs is a pure materializer — route-docs is the planner
# that expands the archetype map into a fully-populated targets[].
# Tests use the realistic two-step flow.
write_api_service_plan() {
  cat > "$TMP/.profile.json" <<'PROFILE'
{
  "name": "stub-api-service",
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
  bash "$ROUTE" --profile "$TMP/.profile.json" --archetype api-service --use-archetype-scaffolds > "$PLAN"
}

# ---- api-reference template ------------------------------------------------

@test "api-reference template has bounded scope per endpoint sections" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/api-reference.md"
  [ -f "$doc" ]
  grep -q "^# API Reference" "$doc"
  grep -q "^## Conventions" "$doc"
  grep -q "^## Endpoints" "$doc"
  grep -q "^## Versioning" "$doc"
}

@test "api-reference template cross-links to architecture, runbook, glossary" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/api-reference.md"
  grep -q "architecture.md" "$doc"
  grep -q "runbook.md" "$doc"
  grep -q "glossary.md" "$doc"
}

# ---- runbook template ------------------------------------------------------

@test "runbook template uses Symptom: pattern for incident response" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/runbook.md"
  [ -f "$doc" ]
  grep -q "^# Runbook" "$doc"
  grep -q "Operational invariants" "$doc"
  grep -q "Symptom:" "$doc"
}

@test "runbook template cross-links to deployment, architecture" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/runbook.md"
  grep -q "deployment.md" "$doc"
  grep -q "architecture.md" "$doc"
}

# ---- deployment template ---------------------------------------------------

@test "deployment template covers topology, pipeline, configuration, rollout" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/deployment.md"
  [ -f "$doc" ]
  grep -q "^# Deployment" "$doc"
  grep -q "^## Topology" "$doc"
  grep -q "^## Pipeline" "$doc"
  grep -q "^## Configuration" "$doc"
  grep -q "^## Rollout model" "$doc"
}

@test "deployment template cross-links to runbook" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/deployment.md"
  grep -q "runbook.md" "$doc"
}

# ---- glossary template -----------------------------------------------------

@test "glossary template has bounded entries with definition + invariants + used-in" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  doc="$TMP/docs/glossary.md"
  [ -f "$doc" ]
  grep -q "^# Glossary" "$doc"
  grep -q "^## Conventions" "$doc"
  grep -q "Definition" "$doc"
  grep -q "Invariants" "$doc"
  grep -q "Used in" "$doc"
}

# ---- Project Memory principles compliance ---------------------------------

@test "all 4 new templates start with H1 and have a See also section" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  for f in api-reference runbook deployment glossary; do
    doc="$TMP/docs/${f}.md"
    [ -f "$doc" ]
    head -1 "$doc" | grep -q "^# "
    grep -q "^## See also" "$doc"
  done
}

@test "all 4 new templates are within reasonable size budget (<6KB)" {
  write_api_service_plan
  bash "$SCAFFOLD" --plan "$PLAN" --target "$TMP" --project-name svc >/dev/null 2>&1
  for f in api-reference runbook deployment glossary; do
    doc="$TMP/docs/${f}.md"
    size=$(wc -c <"$doc" | tr -d ' ')
    [ "$size" -lt 6144 ]
  done
}

# ---- gen-claudemd row labels for new types --------------------------------

@test "gen-claudemd has labels for api_reference, runbook, deployment, glossary" {
  grep -q 'api_reference)' "${REPO_ROOT}/bin/gen-claudemd.sh"
  grep -q 'runbook)' "${REPO_ROOT}/bin/gen-claudemd.sh"
  grep -q 'deployment)' "${REPO_ROOT}/bin/gen-claudemd.sh"
  grep -q 'glossary)' "${REPO_ROOT}/bin/gen-claudemd.sh"
}
