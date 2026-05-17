#!/usr/bin/env bats
# v1.9.0 (Codex review #2): plan-bootstrap.sh enumerates per-workspace writes
# into plan.writes[] when the stack is a monorepo. Without this, bootstrap.sh
# would write workspace docs / gitignore behind the preview's back and break
# undo-bootstrap coverage.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLAN="${REPO_ROOT}/bin/plan-bootstrap.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"

  # Profile with workspaces declared. Each workspace gets its own gitignore
  # + a small scaffold set.
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "monorepo-test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": true},
  "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": ["architecture"], "storage_strategy": "local", "claude_md_mode": "router"},
  "workspaces": {
    "packages/api": {
      "extras": {"gitignore": true},
      "documentation": {"scaffold_types": ["architecture", "prd", "runbook"]}
    },
    "packages/web": {
      "extras": {"gitignore": true},
      "documentation": {"scaffold_types": ["architecture", "adrs"]}
    }
  }
}
EOF

  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "typescript",
  "is_monorepo": true,
  "monorepo_tool": "pnpm-workspaces",
  "workspaces": [
    {"path": "packages/api", "primary_language": "python", "framework": "fastapi", "package_manager": "pip"},
    {"path": "packages/web", "primary_language": "typescript", "framework": "next", "package_manager": "pnpm"}
  ]
}
EOF

  cat > "$TMP/doc-plan.json" <<'EOF'
{
  "storage_strategy": "local",
  "targets": {
    "architecture": {"type": "local", "path": "docs/architecture.md"},
    "adrs": {"type": "local", "path": "docs/decisions"},
    "memory": {"type": "local", "path": "memory"}
  }
}
EOF
}

teardown() { rm -rf "$TMP"; }

run_plan() {
  bash "$PLAN" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" 2>/dev/null
}

@test "monorepo plan includes per-workspace .gitignore for each workspace" {
  json=$(run_plan)
  paths=$(echo "$json" | jq -r '.writes[].path')
  echo "$paths" | grep -Fxq "packages/api/.gitignore"
  echo "$paths" | grep -Fxq "packages/web/.gitignore"
}

@test "monorepo plan includes per-workspace doc scaffolds from scaffold_types" {
  json=$(run_plan)
  paths=$(echo "$json" | jq -r '.writes[].path')
  # packages/api: architecture + prd + runbook
  echo "$paths" | grep -Fxq "packages/api/docs/architecture.md"
  echo "$paths" | grep -Fxq "packages/api/docs/prd.md"
  echo "$paths" | grep -Fxq "packages/api/docs/runbook.md"
  # packages/web: architecture + adrs (ADR README + template)
  echo "$paths" | grep -Fxq "packages/web/docs/architecture.md"
  echo "$paths" | grep -Fxq "packages/web/docs/decisions/README.md"
  echo "$paths" | grep -Fxq "packages/web/docs/decisions/ADR-template.md"
}

@test "non-monorepo plan does NOT include workspace writes" {
  cat > "$TMP/stack.json" <<'EOF'
{"primary_language": "typescript", "is_monorepo": false, "workspaces": []}
EOF
  json=$(run_plan)
  # No path should look like a workspace entry
  workspace_paths=$(echo "$json" | jq -r '[.writes[].path | select(startswith("packages/"))] | length')
  [ "$workspace_paths" -eq 0 ]
}

@test "workspace without extras.gitignore: no workspace .gitignore write emitted" {
  # Override: workspace without gitignore opt-in
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"},
  "workspaces": {
    "packages/api": {
      "documentation": {"scaffold_types": ["architecture"]}
    }
  }
}
EOF
  json=$(run_plan)
  paths=$(echo "$json" | jq -r '.writes[].path')
  # Doc still emitted; gitignore should NOT be
  echo "$paths" | grep -Fxq "packages/api/docs/architecture.md"
  ! echo "$paths" | grep -Fxq "packages/api/.gitignore"
}

@test "workspace path traversal is rejected (no '..' or absolute paths)" {
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"},
  "workspaces": {
    "../escape": {"extras": {"gitignore": true}, "documentation": {"scaffold_types": ["architecture"]}},
    "/abs/path": {"extras": {"gitignore": true}}
  }
}
EOF
  cat > "$TMP/stack.json" <<'EOF'
{"primary_language":"ts","is_monorepo":true,"workspaces":[{"path":"../escape"},{"path":"/abs/path"}]}
EOF
  json=$(run_plan)
  paths=$(echo "$json" | jq -r '.writes[].path')
  ! echo "$paths" | grep -q "\.\."
  ! echo "$paths" | grep -q "^/"
}
