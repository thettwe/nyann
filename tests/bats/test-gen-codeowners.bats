#!/usr/bin/env bats
# bin/gen-codeowners.sh — CODEOWNERS generation tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-codeowners.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"

  WS_CONFIGS="$TMP/ws-configs.json"
}

teardown() { rm -rf "$TMP"; }

make_ws_configs() {
  cat > "$WS_CONFIGS" <<'JSON'
[
  {"path": "packages/api", "language": "typescript", "owner": "@backend-team"},
  {"path": "packages/web", "language": "typescript", "owner": "@frontend-team"},
  {"path": "packages/shared", "language": "typescript"}
]
JSON
}

run_gen() {
  bash "$GEN" --workspace-configs "$WS_CONFIGS" --target "$REPO" "$@"
}

# --- Workspace-to-owner mapping ---

@test "generates CODEOWNERS with workspace paths and owners" {
  make_ws_configs
  run run_gen
  [ "$status" -eq 0 ]
  [ -f "$REPO/.github/CODEOWNERS" ]
  grep -Fq 'packages/api/ @backend-team' "$REPO/.github/CODEOWNERS"
  grep -Fq 'packages/web/ @frontend-team' "$REPO/.github/CODEOWNERS"
}

@test "workspace without owner uses default-owner fallback" {
  make_ws_configs
  run run_gen --default-owner "@org/devs"
  [ "$status" -eq 0 ]
  grep -Fq 'packages/shared/ @org/devs' "$REPO/.github/CODEOWNERS"
}

@test "workspace without owner uses * when no default-owner" {
  make_ws_configs
  run run_gen
  [ "$status" -eq 0 ]
  grep -q 'packages/shared/ \*' "$REPO/.github/CODEOWNERS"
}

# --- Marker idempotency ---

@test "regeneration replaces between markers" {
  make_ws_configs
  run_gen
  # Modify configs and regenerate
  cat > "$WS_CONFIGS" <<'JSON'
[{"path": "apps/mobile", "language": "swift", "owner": "@ios-team"}]
JSON
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq 'apps/mobile/ @ios-team' "$REPO/.github/CODEOWNERS"
  ! grep -Fq 'packages/api/' "$REPO/.github/CODEOWNERS"
}

@test "user content outside markers is preserved" {
  mkdir -p "$REPO/.github"
  cat > "$REPO/.github/CODEOWNERS" <<'CO'
# Team leads
* @cto
# nyann:codeowners:start
old content
# nyann:codeowners:end
# Custom rules
docs/ @tech-writer
CO
  make_ws_configs
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq '# Team leads' "$REPO/.github/CODEOWNERS"
  grep -Fq 'docs/ @tech-writer' "$REPO/.github/CODEOWNERS"
  ! grep -Fq 'old content' "$REPO/.github/CODEOWNERS"
}

# --- Non-monorepo skip ---

@test "no workspace configs → exits silently" {
  run bash "$GEN" --target "$REPO"
  [ "$status" -eq 0 ]
}

@test "empty workspace configs → exits silently" {
  echo '[]' > "$WS_CONFIGS"
  run run_gen
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.github/CODEOWNERS" ]
}

# --- Dry-run ---

@test "dry-run prints content without writing" {
  make_ws_configs
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.github/CODEOWNERS" ]
  [[ "$output" == *"nyann:codeowners:start"* ]]
  [[ "$output" == *"packages/api/ @backend-team"* ]]
}

# --- End-to-end pipeline lock -----------------------------------------------
# All other tests above inject hand-built workspace-config JSON, which
# never exercises the profile -> resolver -> codeowners pipeline. If
# the resolver silently drops profile.workspaces.<key>.owner, the
# hand-built fixture style hides it. These tests drive the real
# resolver on a real profile and assert the owner reaches CODEOWNERS.

@test "profile workspaces.owner flows through resolver into CODEOWNERS" {
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "typescript",
  "is_monorepo": true,
  "monorepo_tool": "pnpm-workspaces",
  "workspaces": [
    {"path": "packages/api", "primary_language": "python",     "framework": "fastapi", "package_manager": "pip"},
    {"path": "packages/web", "primary_language": "typescript", "framework": "next",    "package_manager": "pnpm"}
  ]
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
    "packages/api": { "owner": "@backend-team" },
    "packages/web": { "owner": "@frontend-team" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" > "$WS_CONFIGS"
  run bash "$GEN" --workspace-configs "$WS_CONFIGS" --target "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.github/CODEOWNERS" ]
  grep -Fq 'packages/api/ @backend-team'  "$REPO/.github/CODEOWNERS"
  grep -Fq 'packages/web/ @frontend-team' "$REPO/.github/CODEOWNERS"
}

@test "profile wildcard owner flows through resolver into CODEOWNERS" {
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "typescript",
  "is_monorepo": true,
  "workspaces": [
    {"path": "packages/api", "primary_language": "python",     "framework": null, "package_manager": "pip"},
    {"path": "packages/web", "primary_language": "typescript", "framework": null, "package_manager": "pnpm"}
  ]
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
    "*": { "owner": "@platform-team" }
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
EOF
  bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "$TMP/profile.json" > "$WS_CONFIGS"
  run bash "$GEN" --workspace-configs "$WS_CONFIGS" --target "$REPO"
  [ "$status" -eq 0 ]
  grep -Fq 'packages/api/ @platform-team' "$REPO/.github/CODEOWNERS"
  grep -Fq 'packages/web/ @platform-team' "$REPO/.github/CODEOWNERS"
}
