#!/usr/bin/env bats
# bin/retrofit.sh + bin/compute-drift.sh against the legacy fixture.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RETROFIT="${REPO_ROOT}/bin/retrofit.sh"
  SCHEMA="${REPO_ROOT}/schemas/drift-report.schema.json"
  TMP="$(mktemp -d)"
  cp -r "${REPO_ROOT}/tests/fixtures/legacy-with-drift/." "${TMP}/"
  ( cd "$TMP" && ./seed.sh >/dev/null 2>&1 )
}

teardown() { rm -rf "$TMP"; }

@test "legacy fixture → retrofit --json emits schema-valid report with all three sections populated" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json
  [ "$status" -eq 0 ]
  # Must have non-empty missing/misconfigured/non_compliant_history.
  [ "$(echo "$output" | jq '.summary.missing')"               -gt 0 ]
  [ "$(echo "$output" | jq '.summary.misconfigured')"         -gt 0 ]
  [ "$(echo "$output" | jq '.summary.non_compliant_commits')" -gt 0 ]
}

@test "legacy fixture → retrofit text output names each of the three sections" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --report-only
  [ "$status" -eq 5 ]   # missing hygiene → critical
  echo "$output" | grep -q 'MISSING:'
  echo "$output" | grep -q 'MISCONFIGURED:'
  echo "$output" | grep -q 'NON-COMPLIANT HISTORY'
  echo "$output" | grep -q 'DOCUMENTATION:'
}

@test "legacy fixture → non-compliant history entries are flagged but no rewrite is offered" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --report-only
  # Info-only phrase must be present; no 'rebase' or 'filter-branch' in output.
  echo "$output" | grep -q "informational only"
  ! echo "$output" | grep -Eq 'git rebase|filter-branch'
}

@test "clean repo → exit 0 and no drift detected" {
  clean="$(mktemp -d)"
  mkdir -p "$clean/docs/decisions" "$clean/memory" "$clean/.husky"
  ( cd "$clean" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: init" )
  echo '{}' > "$clean/.husky/pre-commit"
  echo '{}' > "$clean/.husky/commit-msg"
  printf '# test\n' > "$clean/CLAUDE.md"
  printf '# Architecture\n' > "$clean/docs/architecture.md"
  printf '# ADR-000\n' > "$clean/docs/decisions/ADR-000-record-architecture-decisions.md"
  printf '# readme\n' > "$clean/memory/README.md"
  printf '' > "$clean/.gitignore"
  run bash "$RETROFIT" --target "$clean" --profile default --report-only
  rm -rf "$clean"
  # Warnings-only or clean (exit 0 or 4; not critical 5)
  [[ "$status" -eq 0 || "$status" -eq 4 ]]
}

@test "legacy fixture → exit 5 for critical drift" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --report-only
  [ "$status" -eq 5 ]
}

@test "legacy fixture → --json output has documentation section" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'has("documentation")')" = "true" ]
  [ "$(echo "$output" | jq '.documentation | has("claude_md")')" = "true" ]
  [ "$(echo "$output" | jq '.documentation | has("links")')" = "true" ]
}

@test "legacy fixture → --json has subsystem_errors field" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'has("summary")')" = "true" ]
  [ "$(echo "$output" | jq '.summary | has("subsystem_errors")')" = "true" ]
}

@test "legacy fixture → drift report validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator available"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  out=$(bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json)
  echo "$out" > "$TMP/report.json"
  run "${validator[@]}" --schemafile "$SCHEMA" "$TMP/report.json"
  [ "$status" -eq 0 ]
}

# v1.6.0 — archetype-aware drift surfacing
# When profile.documentation.use_archetype_scaffolds is true and
# profile.archetype is set, compute-drift expands the expected doc
# set with the per-archetype map. Missing archetype-specific docs
# (api-reference / runbook / deployment / glossary) surface as
# `missing` entries.
@test "archetype-aware drift surfaces missing api-reference / runbook / deployment / glossary" {
  AT="$TMP/archetype-repo"
  mkdir -p "$AT"
  ( cd "$AT" && git init -q -b main && \
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  # Profile: api-service archetype + use_archetype_scaffolds:true
  cat > "$AT/.profile.json" <<'JSON'
{
  "name": "api-svc-test",
  "schemaVersion": 1,
  "archetype": "api-service",
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "conventions": {"commit_format": "conventional-commits"},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": false, "editorconfig": false, "claude_md": false, "github_actions_ci": false, "commit_message_template": false, "github_templates": false},
  "documentation": {
    "scaffold_types": ["architecture", "adrs"],
    "use_archetype_scaffolds": true,
    "storage_strategy": "local",
    "preferred_mcp": null,
    "adr_format": "madr",
    "claude_md_mode": "router",
    "claude_md_size_budget_kb": 3,
    "staleness_days": null,
    "enable_drift_checks": {"broken_internal_links": false, "broken_mcp_links": false, "orphans": false, "staleness": false}
  }
}
JSON
  report=$(bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$AT" --profile "$AT/.profile.json")
  # All four archetype-only doc types must surface as missing.
  [ "$(echo "$report" | jq -r '[.missing[].path] | sort | join(",")')" != "" ]
  echo "$report" | jq -e '.missing[] | select(.path == "docs/api-reference.md")' >/dev/null
  echo "$report" | jq -e '.missing[] | select(.path == "docs/runbook.md")' >/dev/null
  echo "$report" | jq -e '.missing[] | select(.path == "docs/deployment.md")' >/dev/null
  echo "$report" | jq -e '.missing[] | select(.path == "docs/glossary.md")' >/dev/null
}

@test "archetype-aware drift suppressed when use_archetype_scaffolds is false" {
  AT="$TMP/archetype-off"
  mkdir -p "$AT"
  ( cd "$AT" && git init -q -b main && \
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  cat > "$AT/.profile.json" <<'JSON'
{
  "name": "api-svc-flagged-off",
  "schemaVersion": 1,
  "archetype": "api-service",
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "conventions": {"commit_format": "conventional-commits"},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": false, "editorconfig": false, "claude_md": false, "github_actions_ci": false, "commit_message_template": false, "github_templates": false},
  "documentation": {
    "scaffold_types": ["architecture", "adrs"],
    "use_archetype_scaffolds": false,
    "storage_strategy": "local",
    "preferred_mcp": null,
    "adr_format": "madr",
    "claude_md_mode": "router",
    "claude_md_size_budget_kb": 3,
    "staleness_days": null,
    "enable_drift_checks": {"broken_internal_links": false, "broken_mcp_links": false, "orphans": false, "staleness": false}
  }
}
JSON
  report=$(bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$AT" --profile "$AT/.profile.json")
  # archetype-only docs MUST NOT surface — flag is off, so flat list applies.
  ! echo "$report" | jq -e '.missing[] | select(.path == "docs/api-reference.md")' >/dev/null
  ! echo "$report" | jq -e '.missing[] | select(.path == "docs/runbook.md")' >/dev/null
}
