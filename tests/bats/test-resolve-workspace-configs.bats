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

@test "named profile + wildcard: wildcard hooks/extras layer onto named profile" {
  write_stack
  # Create a named profile that the workspace will reference
  mkdir -p "$TMP/plugin/profiles"
  cat > "$TMP/plugin/profiles/react-vite.json" <<'EOF'
{
  "name": "react-vite", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": ["eslint"], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": false, "editorconfig": false},
  "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  # Profile assigns named profile to web, wildcard adds shared policy
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": { "profile": "react-vite" },
    "*": { "extras": {"gitignore": true, "editorconfig": true}, "owner": "@platform" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" \
    --plugin-root "$TMP/plugin"
  [ "$status" -eq 0 ]
  # The named-profile workspace (packages/web) must pick up wildcard extras
  web_gi=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .extras.gitignore')
  web_ec=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .extras.editorconfig')
  [ "$web_gi" = "true" ]
  [ "$web_ec" = "true" ]
  # Named profile's hooks should still be the base
  web_hooks=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .hooks.pre_commit | join(",")')
  [[ "$web_hooks" == *"eslint"* ]]
  # Owner from wildcard
  web_owner=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .owner')
  [ "$web_owner" = "@platform" ]
}

@test "named profile + exact override: exact beats wildcard and named profile" {
  write_stack
  mkdir -p "$TMP/plugin/profiles"
  cat > "$TMP/plugin/profiles/react-vite.json" <<'EOF'
{
  "name": "react-vite", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": ["eslint"], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": false, "editorconfig": false},
  "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": { "profile": "react-vite", "extras": {"gitignore": true}, "owner": "@web-team" },
    "*": { "extras": {"editorconfig": true}, "owner": "@platform" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" \
    --plugin-root "$TMP/plugin"
  [ "$status" -eq 0 ]
  # Exact override sets gitignore=true, wildcard sets editorconfig=true — both apply
  web_gi=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .extras.gitignore')
  web_ec=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .extras.editorconfig')
  [ "$web_gi" = "true" ]
  [ "$web_ec" = "true" ]
  # Exact-path owner beats wildcard owner
  web_owner=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .owner')
  [ "$web_owner" = "@web-team" ]
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

@test "named profile + inline ci override: exact ci wins over named profile ci" {
  # Regression guard: previously the named-profile branch only merged
  # hooks/extras/owner in the exact-override layer. ci/documentation
  # were forwarded from the named profile and inline workspace overrides
  # were silently dropped, making per-workspace CI opt-outs impossible.
  write_stack
  mkdir -p "$TMP/plugin/profiles"
  cat > "$TMP/plugin/profiles/react-vite.json" <<'EOF'
{
  "name": "react-vite", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": ["eslint"], "commit_msg": [], "pre_push": []},
  "extras": {"gitignore": false, "editorconfig": false},
  "conventions": {"commit_format": "conventional-commits"},
  "ci": {"enabled": true, "node_version": "20"},
  "documentation": {"scaffold_types": ["architecture"], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": {
      "profile": "react-vite",
      "ci": {"enabled": false, "lint": false},
      "documentation": {"scaffold_types": ["prd"]}
    }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" \
    --plugin-root "$TMP/plugin"
  [ "$status" -eq 0 ]
  # Inline ci.enabled override wins: false (named profile said true)
  web_ci_enabled=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .ci.enabled')
  [ "$web_ci_enabled" = "false" ]
  # Inline lint=false override is preserved
  web_ci_lint=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .ci.lint')
  [ "$web_ci_lint" = "false" ]
  # Inline documentation override wins: scaffold_types=["prd"] (named profile said ["architecture"])
  web_doc=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .documentation.scaffold_types | join(",")')
  [ "$web_doc" = "prd" ]
  # Fields not in the inline override deep-merge from the named profile.
  # The named profile declared node_version=20; the inline override didn't
  # touch it, so it must survive.
  web_ci_node=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .ci.node_version')
  [ "$web_ci_node" = "20" ]
}

@test "named profile + wildcard ci/documentation override: wildcard merges onto named profile" {
  write_stack
  mkdir -p "$TMP/plugin/profiles"
  cat > "$TMP/plugin/profiles/react-vite.json" <<'EOF'
{
  "name": "react-vite", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": ["eslint"], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "ci": {"enabled": true, "node_version": "20"},
  "documentation": {"scaffold_types": ["architecture"], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": { "profile": "react-vite" },
    "*": { "ci": {"typecheck": true} }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" \
    --plugin-root "$TMP/plugin"
  [ "$status" -eq 0 ]
  # Wildcard's ci.typecheck merges onto named profile's ci object
  web_ci_typecheck=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .ci.typecheck')
  [ "$web_ci_typecheck" = "true" ]
  # Named profile's ci.enabled preserved through the merge
  web_ci_enabled=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .ci.enabled')
  [ "$web_ci_enabled" = "true" ]
  # Named profile's ci.node_version preserved
  web_ci_node=$(echo "$output" | jq -r '.[] | select(.path == "packages/web") | .ci.node_version')
  [ "$web_ci_node" = "20" ]
}

@test "load_named_profile rejects path traversal in profile name (security)" {
  write_stack
  mkdir -p "$TMP/plugin/profiles"
  cat > "$TMP/profile.json" <<EOF
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/web": { "profile": "../../etc/passwd" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" \
    --plugin-root "$TMP/plugin"
  # Resolver should warn + fall back to defaults, NOT cat an arbitrary file.
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "profile name rejected"
}

@test "exact override forwards inline documentation + ci to entry (Codex regression)" {
  # Before the v1.9.0 Codex fix, an inline workspace override with
  # documentation.scaffold_types was dropped — plan-bootstrap.sh then
  # couldn't enumerate workspace docs. Regression guard: assert both
  # documentation and ci are forwarded to the resolver output.
  write_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "packages/api": {
      "documentation": {"scaffold_types": ["architecture", "prd"]},
      "ci": {"enabled": true, "lint": true}
    }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  doc_types=$(echo "$output" | jq -r '.[0].documentation.scaffold_types | join(",")')
  [ "$doc_types" = "architecture,prd" ]
  ci_enabled=$(echo "$output" | jq -r '.[0].ci.enabled')
  [ "$ci_enabled" = "true" ]
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

# --- IaC units as workspaces (v1.13.0 I7) ------------------------------------
# detect-stack emits iac.units[]; the resolver folds non-root units into the
# workspace list so per-workspace machinery (versioning especially) keys off
# real IaC unit paths. Synthesized entries get LANGUAGE DEFAULTS only (hcl/yaml
# → [] hooks) plus any explicit profile override — no forced per-unit CI/docs.

# An IaC-only terraform descriptor: NOT is_monorepo, but carries iac.units.
write_iac_only_stack() {
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "hcl",
  "is_monorepo": false,
  "workspaces": [],
  "iac": {
    "tool": "terraform",
    "language": "hcl",
    "units": [
      {"kind": "stack",  "path": ".",                  "name": "root",       "version": null},
      {"kind": "stack",  "path": "environments/prod",  "name": "prod",       "version": null, "depends_on": ["modules/db"]},
      {"kind": "module", "path": "modules/db",         "name": "db",         "version": null, "depends_on": ["modules/networking"]},
      {"kind": "module", "path": "modules/networking", "name": "networking", "version": null}
    ],
    "lockfiles": [],
    "var_files": []
  }
}
EOF
}

@test "iac-only repo (not is_monorepo): iac.units become workspaces, root '.' excluded" {
  write_iac_only_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # 3 of 4 units become workspaces — the root "." unit is dropped (path-safety
  # guard + a repo-root unit is not a sub-workspace).
  [ "$(echo "$output" | jq 'length')" -eq 3 ]
  echo "$output" | jq -e 'all(.[]; .path != ".")'
  echo "$output" | jq -e 'any(.[]; .path == "environments/prod")'
  echo "$output" | jq -e 'any(.[]; .path == "modules/db")'
  echo "$output" | jq -e 'any(.[]; .path == "modules/networking")'
}

@test "iac unit workspace carries iac.language + iac.tool, null package_manager" {
  write_iac_only_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  db=$(echo "$output" | jq -c '.[] | select(.path == "modules/db")')
  [ "$(echo "$db" | jq -r '.primary_language')" = "hcl" ]
  [ "$(echo "$db" | jq -r '.framework')" = "terraform" ]
  [ "$(echo "$db" | jq -r '.package_manager')" = "null" ]
}

@test "iac unit workspace: hcl gets [] default hooks, no forced ci/docs" {
  write_iac_only_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # hcl/yaml → empty default hooks (safe no-op).
  echo "$output" | jq -e 'all(.[]; .hooks.pre_commit == [])'
  # No ci / documentation forced onto a bare IaC unit (opt-in via profile only).
  echo "$output" | jq -e 'all(.[]; has("ci") | not)'
  echo "$output" | jq -e 'all(.[]; has("documentation") | not)'
}

@test "iac unit workspaces validate against the workspace-configs schema" {
  write_iac_only_stack
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  if command -v check-jsonschema >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1; then
    echo "$output" > "$TMP/resolved.json"
    if command -v check-jsonschema >/dev/null 2>&1; then
      check-jsonschema --schemafile "${REPO_ROOT}/schemas/workspace-configs.schema.json" "$TMP/resolved.json"
    else
      uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/workspace-configs.schema.json" "$TMP/resolved.json"
    fi
  else
    skip "check-jsonschema not available"
  fi
}

@test "profile wildcard can opt an iac unit into hooks (override still applies)" {
  write_iac_only_stack
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "unknown"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "workspaces": {
    "*": { "hooks": {"pre_commit": ["terraform-fmt"]} }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # The wildcard hook override reaches synthesized IaC unit workspaces.
  echo "$output" | jq -e 'all(.[]; .hooks.pre_commit | index("terraform-fmt"))'
}

@test "iac unit already present as a real workspace is not duplicated" {
  # A JS/TS monorepo that ALSO has an iac block whose unit path collides with a
  # real workspace path: the real workspace wins, no duplicate entry.
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "typescript",
  "is_monorepo": true,
  "monorepo_tool": "pnpm-workspaces",
  "workspaces": [
    {"path": "infra", "primary_language": "typescript", "framework": "next", "package_manager": "pnpm"}
  ],
  "iac": {
    "tool": "terraform",
    "language": "hcl",
    "units": [
      {"kind": "stack", "path": "infra", "name": "infra", "version": null}
    ],
    "lockfiles": [],
    "var_files": []
  }
}
EOF
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # exactly one entry for "infra" — the real workspace (typescript), not a dup.
  [ "$(echo "$output" | jq '[.[] | select(.path == "infra")] | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.[] | select(.path == "infra") | .primary_language')" = "typescript" ]
}

@test "iac-only repo with ONLY a root unit resolves to empty (root excluded)" {
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "yaml",
  "is_monorepo": false,
  "workspaces": [],
  "iac": {
    "tool": "helm",
    "language": "yaml",
    "units": [
      {"kind": "chart", "path": ".", "name": "my-chart", "version": "1.0.0"}
    ],
    "lockfiles": [],
    "var_files": []
  }
}
EOF
  write_profile_no_ws
  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  # Only a root unit → no sub-workspaces → empty array (versioning sees the
  # root unit via iac.units[] directly; it needs no workspace shim).
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}
