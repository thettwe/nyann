#!/usr/bin/env bats
# bin/gen-ci.sh — CI workflow generation tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-ci.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"

  PROFILE="$TMP/profile.json"
  STACK="$TMP/stack.json"
}

teardown() { rm -rf "$TMP"; }

make_profile() {
  local lang="${1:-typescript}" pkg="${2:-npm}"
  cat > "$PROFILE" <<JSON
{
  "name": "test-profile",
  "schemaVersion": 1,
  "stack": { "primary_language": "$lang", "framework": null, "package_manager": "$pkg" },
  "branching": { "strategy": "github-flow", "base_branches": ["main"] },
  "hooks": { "pre_commit": ["eslint", "prettier"], "commit_msg": ["conventional-commits"], "pre_push": [] },
  "extras": { "gitignore": true, "editorconfig": false, "claude_md": true, "github_actions_ci": true, "commit_message_template": false },
  "conventions": { "commit_format": "conventional-commits" },
  "ci": { "enabled": true, "node_version": "20" },
  "documentation": { "scaffold_types": [], "storage_strategy": "local", "preferred_mcp": null, "adr_format": "madr", "claude_md_mode": "router", "claude_md_size_budget_kb": 3, "staleness_days": null, "enable_drift_checks": { "broken_internal_links": true, "broken_mcp_links": true, "orphans": true, "staleness": false } }
}
JSON
}

make_stack() {
  local lang="${1:-typescript}"
  cat > "$STACK" <<JSON
{ "primary_language": "$lang", "secondary_languages": [], "is_monorepo": false }
JSON
}

run_gen() {
  bash "$GEN" --profile "$PROFILE" --stack "$STACK" --target "$REPO" "$@"
}

# --- Template selection per stack ---

@test "typescript stack → selects typescript template" {
  make_profile typescript pnpm
  make_stack typescript
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"node-version"* ]]
  [[ "$output" == *"pnpm"* ]]
}

@test "python stack → selects python template" {
  make_profile python pip
  make_stack python
  # Update hooks for python
  jq '.hooks.pre_commit = ["ruff", "ruff-format"]' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  jq '.ci = { "enabled": true, "python_version": "3.12" }' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"python-version"* ]]
  [[ "$output" == *"ruff"* ]]
}

@test "go stack → selects go template" {
  make_profile go go
  make_stack go
  jq '.hooks.pre_commit = ["gofmt", "go-vet", "golangci-lint"]' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  jq '.ci = { "enabled": true, "go_version": "1.22" }' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"go-version"* ]]
  [[ "$output" == *"golangci-lint"* ]]
}

@test "rust stack → selects rust template" {
  make_profile rust cargo
  make_stack rust
  jq '.hooks.pre_commit = ["fmt", "clippy"]' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  jq '.ci = { "enabled": true }' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"cargo fmt"* ]]
  [[ "$output" == *"cargo clippy"* ]]
}

@test "unknown stack → selects generic template" {
  make_profile unknown unknown
  make_stack unknown
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  # Generic template ships failing placeholder steps so an unconfigured
  # workflow doesn't pretend to be green. The exact wording lives in
  # templates/ci/generic.yml.
  [[ "$output" == *"Replace this step with your linter"* ]]
}

# --- Marker idempotency ---

@test "no existing ci.yml → creates file with markers" {
  make_profile typescript npm
  make_stack typescript
  run run_gen
  [ "$status" -eq 0 ]
  [ -f "$REPO/.github/workflows/ci.yml" ]
  grep -Fq '# nyann:ci:start' "$REPO/.github/workflows/ci.yml"
  grep -Fq '# nyann:ci:end' "$REPO/.github/workflows/ci.yml"
}

@test "existing ci.yml with markers → replaces between markers" {
  make_profile typescript npm
  make_stack typescript
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yml" <<'YML'
# User preamble
# nyann:ci:start
old generated content
# nyann:ci:end
# User postamble
YML
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq "User preamble" "$REPO/.github/workflows/ci.yml"
  grep -Fq "User postamble" "$REPO/.github/workflows/ci.yml"
  ! grep -Fq "old generated content" "$REPO/.github/workflows/ci.yml"
  grep -Fq "node-version" "$REPO/.github/workflows/ci.yml"
}

@test "existing ci.yml without markers → skipped without --allow-merge-existing" {
  make_profile typescript npm
  make_stack typescript
  mkdir -p "$REPO/.github/workflows"
  echo "# Custom workflow" > "$REPO/.github/workflows/ci.yml"
  run run_gen
  [ "$status" -eq 0 ]
  # User content untouched; no nyann block leaked in silently.
  grep -Fxq "# Custom workflow" "$REPO/.github/workflows/ci.yml"
  ! grep -Fq "# nyann:ci:start" "$REPO/.github/workflows/ci.yml"
}

@test "existing ci.yml without markers → --allow-merge-existing appends block" {
  make_profile typescript npm
  make_stack typescript
  mkdir -p "$REPO/.github/workflows"
  echo "# Custom workflow" > "$REPO/.github/workflows/ci.yml"
  run run_gen --allow-merge-existing
  [ "$status" -eq 0 ]
  # User content preserved AND nyann block appended.
  grep -Fxq "# Custom workflow" "$REPO/.github/workflows/ci.yml"
  grep -Fq "# nyann:ci:start" "$REPO/.github/workflows/ci.yml"
}

# --- Dry-run ---

@test "dry-run prints workflow but does not write file" {
  make_profile typescript npm
  make_stack typescript
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.github/workflows/ci.yml" ]
  [[ "$output" == *"nyann:ci:start"* ]]
}

# --- Base branches substitution ---

@test "base branches from profile are substituted" {
  make_profile typescript npm
  make_stack typescript
  jq '.branching.base_branches = ["main", "develop"]' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"main, develop"* ]]
}

# --- Error cases ---

@test "missing --stack → dies" {
  make_profile typescript npm
  run bash "$GEN" --profile "$PROFILE" --target "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--stack"* ]]
}

@test "missing --profile → dies" {
  make_stack typescript
  run bash "$GEN" --stack "$STACK" --target "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile"* ]]
}
