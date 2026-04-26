#!/usr/bin/env bats
# Tests for bin/resolve-workspace-configs.sh — workspace config merging.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

write_stack() {
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "javascript",
  "is_monorepo": true,
  "monorepo_tool": "pnpm-workspaces",
  "workspaces": [
    {"path": "packages/api", "primary_language": "python", "framework": "fastapi", "package_manager": "pip"},
    {"path": "packages/web", "primary_language": "typescript", "framework": "next", "package_manager": "pnpm"}
  ]
}
EOF
}

write_profile_no_ws() {
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": ["block-main"], "commit_msg": ["conventional-commits"], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
}

@test "non-monorepo emits empty array" {
  echo '{"is_monorepo": false, "workspaces": []}' > "$TMP/stack.json"
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "language-based defaults: python gets ruff, typescript gets eslint" {
  write_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]

  # Python workspace
  api_hooks=$(echo "$output" | jq -r '.[0].hooks.pre_commit | join(",")')
  [ "$api_hooks" = "ruff,ruff-format" ]

  # TypeScript workspace
  web_hooks=$(echo "$output" | jq -r '.[1].hooks.pre_commit | join(",")')
  [ "$web_hooks" = "eslint,prettier" ]
}

@test "exact-path override replaces defaults" {
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": {
      "hooks": {"pre_commit": ["eslint", "prettier", "stylelint"]}
    }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]

  web_hooks=$(echo "$output" | jq -r '.[1].hooks.pre_commit | join(",")')
  [ "$web_hooks" = "eslint,prettier,stylelint" ]

  # api has no override → uses language defaults
  api_hooks=$(echo "$output" | jq -r '.[0].hooks.pre_commit | join(",")')
  [ "$api_hooks" = "ruff,ruff-format" ]
}

@test "wildcard override applies to unmatched workspaces" {
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": {
      "hooks": {"pre_commit": ["eslint"]}
    },
    "*": {
      "hooks": {"pre_commit": ["prettier"]},
      "extras": {"editorconfig": true}
    }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]

  # api matches wildcard
  api_hooks=$(echo "$output" | jq -r '.[0].hooks.pre_commit | join(",")')
  [ "$api_hooks" = "prettier" ]
  api_ec=$(echo "$output" | jq -r '.[0].extras.editorconfig')
  [ "$api_ec" = "true" ]

  # web has exact match — wildcard doesn't apply
  web_hooks=$(echo "$output" | jq -r '.[1].hooks.pre_commit | join(",")')
  [ "$web_hooks" = "eslint" ]
}

@test "output includes path, language, framework, package_manager" {
  write_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]

  [ "$(echo "$output" | jq -r '.[0].path')" = "packages/api" ]
  [ "$(echo "$output" | jq -r '.[0].primary_language')" = "python" ]
  [ "$(echo "$output" | jq -r '.[0].framework')" = "fastapi" ]
  [ "$(echo "$output" | jq -r '.[1].path')" = "packages/web" ]
  [ "$(echo "$output" | jq -r '.[1].framework')" = "next" ]
}

@test "missing --stack flag dies with usage" {
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" --profile "$TMP/profile.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--stack"* ]]
}

# --- Owner forwarding lock ---------------------------------------------------
# profile.workspaces.<key>.owner is declared in profiles/_schema.json
# and consumed by gen-codeowners.sh, but the resolver sits between
# them. If the resolver doesn't forward the field, every workspace
# falls back to gen-codeowners' --default-owner ("*") and the profile
# field becomes a no-op. These tests lock the field flowing through
# the resolver -> workspace-configs entry contract.

@test "exact-path override forwards owner field to entry" {
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/api": { "owner": "@backend-team" },
    "packages/web": { "owner": "@frontend-team" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].owner')" = "@backend-team" ]
  [ "$(echo "$output" | jq -r '.[1].owner')" = "@frontend-team" ]
}

@test "wildcard override forwards owner to unmatched workspaces" {
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": { "owner": "@frontend-team" },
    "*": { "owner": "@platform-team" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # api has no exact match → wildcard wins
  [ "$(echo "$output" | jq -r '.[0].owner')" = "@platform-team" ]
  # web has exact match → exact wins
  [ "$(echo "$output" | jq -r '.[1].owner')" = "@frontend-team" ]
}

@test "exact override without owner falls through to wildcard owner" {
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": { "hooks": {"pre_commit": ["eslint"]} },
    "*": { "owner": "@platform-team" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # web's exact override has no owner; wildcard provides it.
  # If owner falls through correctly, both workspaces should report
  # @platform-team.
  [ "$(echo "$output" | jq -r '.[0].owner')" = "@platform-team" ]
  [ "$(echo "$output" | jq -r '.[1].owner')" = "@platform-team" ]
}

@test "no owner declared anywhere → entry omits owner field (gen-codeowners falls back)" {
  write_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # owner key absent — explicit empty-string would be wrong because
  # gen-codeowners.sh treats "" the same as missing, but the schema
  # also forbids it (must match @<handle> pattern). So the resolver
  # must omit the key entirely when no owner is declared.
  [ "$(echo "$output" | jq '.[0] | has("owner")')" = "false" ]
  [ "$(echo "$output" | jq '.[1] | has("owner")')" = "false" ]
}

@test "resolver output validates against the workspace-configs schema" {
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/api": { "owner": "@backend-team" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # Use the same validator the rest of the suite uses (skip if unavailable).
  if command -v check-jsonschema >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1; then
    output_file="$TMP/resolved.json"
    echo "$output" > "$output_file"
    if command -v check-jsonschema >/dev/null 2>&1; then
      check-jsonschema --schemafile "${REPO_ROOT}/schemas/workspace-configs.schema.json" "$output_file"
    else
      uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/workspace-configs.schema.json" "$output_file"
    fi
  else
    skip "check-jsonschema not available"
  fi
}

@test "rust workspace gets fmt + clippy defaults (matches installed hooks)" {
  # Hook IDs must match what the rust pre-commit template actually
  # exposes (doublify/pre-commit-rust → fmt + clippy). cargo-check /
  # rustfmt would be unsupported IDs that don't run.
  cat > "$TMP/stack.json" <<'EOF'
{
  "is_monorepo": true,
  "workspaces": [
    {"path": "crates/cli", "primary_language": "rust", "framework": null, "package_manager": "cargo"}
  ]
}
EOF
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  hooks=$(echo "$output" | jq -r '.[0].hooks.pre_commit | join(",")')
  [ "$hooks" = "fmt,clippy" ]
}

@test "go workspace gets go-vet and gofmt defaults" {
  cat > "$TMP/stack.json" <<'EOF'
{
  "is_monorepo": true,
  "workspaces": [
    {"path": "services/gateway", "primary_language": "go", "framework": null, "package_manager": "go"}
  ]
}
EOF
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  hooks=$(echo "$output" | jq -r '.[0].hooks.pre_commit | join(",")')
  [ "$hooks" = "go-vet,gofmt" ]
}
