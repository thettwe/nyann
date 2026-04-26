#!/usr/bin/env bats
# bin/suggest-profile-updates.sh — profile suggestion engine tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUGGEST="${REPO_ROOT}/bin/suggest-profile-updates.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -b main >/dev/null 2>&1
  git -C "$REPO" config user.email "test@test.com"
  git -C "$REPO" config user.name "Test"

  PROFILE="$TMP/profile.json"
}

teardown() { rm -rf "$TMP"; }

make_profile() {
  cat > "$PROFILE" <<'JSON'
{
  "name": "test-profile",
  "schemaVersion": 1,
  "stack": { "primary_language": "typescript", "framework": null, "package_manager": "npm" },
  "branching": { "strategy": "github-flow", "base_branches": ["main"] },
  "hooks": { "pre_commit": ["eslint"], "commit_msg": ["conventional-commits"], "pre_push": [] },
  "extras": { "gitignore": true },
  "conventions": { "commit_format": "conventional-commits", "commit_scopes": [] },
  "workspaces": {}
}
JSON
}

make_profile_no_hooks() {
  cat > "$PROFILE" <<'JSON'
{
  "name": "test-profile",
  "schemaVersion": 1,
  "stack": { "primary_language": "typescript", "framework": null, "package_manager": "npm" },
  "branching": { "strategy": "github-flow", "base_branches": ["main"] },
  "hooks": { "pre_commit": [], "commit_msg": [], "pre_push": [] },
  "extras": { "gitignore": true },
  "conventions": { "commit_format": "custom", "commit_scopes": [] },
  "workspaces": {}
}
JSON
}

# --- Signal 1: devDependencies ---

@test "detects eslint in devDeps but not in hooks" {
  make_profile_no_hooks
  cat > "$REPO/package.json" <<'JSON'
{ "devDependencies": { "eslint": "^9.0.0" } }
JSON
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.category == "hook-gap" and .action.add == "eslint")) | length > 0'
}

@test "no suggestion when hook already present" {
  make_profile
  cat > "$REPO/package.json" <<'JSON'
{ "devDependencies": { "eslint": "^9.0.0" } }
JSON
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq 'map(select(.category == "hook-gap" and .action.add == "eslint")) | length')
  [ "$count" -eq 0 ]
}

@test "detects prettier in devDeps missing from hooks" {
  make_profile_no_hooks
  cat > "$REPO/package.json" <<'JSON'
{ "devDependencies": { "prettier": "^3.0.0" } }
JSON
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.action.add == "prettier")) | length > 0'
}

# --- Signal 2: Config files ---

@test "detects config file without matching hook" {
  make_profile_no_hooks
  touch "$REPO/.prettierrc.json"
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.category == "config-present" and .action.add == "prettier")) | length > 0'
}

@test "deduplicates dep and config signals for same tool" {
  make_profile_no_hooks
  cat > "$REPO/package.json" <<'JSON'
{ "devDependencies": { "prettier": "^3.0.0" } }
JSON
  touch "$REPO/.prettierrc.json"
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq 'map(select(.action.add == "prettier")) | length')
  [ "$count" -eq 1 ]
}

# --- Signal 3: Monorepo detection ---

@test "detects monorepo workspaces field" {
  make_profile
  cat > "$REPO/package.json" <<'JSON'
{ "workspaces": ["packages/*"] }
JSON
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.category == "structure")) | length > 0'
}

@test "detects pnpm-workspace.yaml" {
  make_profile
  echo "packages:" > "$REPO/pnpm-workspace.yaml"
  echo "  - 'packages/*'" >> "$REPO/pnpm-workspace.yaml"
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.category == "structure")) | length > 0'
}

# --- Signal 4: Git history ---

@test "suggests conventional-commits when >80% match" {
  make_profile_no_hooks
  # Create 10 conventional commits
  for i in $(seq 1 10); do
    touch "$REPO/file${i}.txt"
    git -C "$REPO" add "file${i}.txt"
    git -C "$REPO" commit -m "feat: add feature ${i}" --allow-empty >/dev/null 2>&1
  done
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.category == "history-drift" and (.suggestion | test("conventional-commits")))) | length > 0'
}

@test "detects commit scopes not in profile" {
  make_profile
  for scope in core ui api; do
    touch "$REPO/file-${scope}.txt"
    git -C "$REPO" add "file-${scope}.txt"
    git -C "$REPO" commit -m "feat(${scope}): add ${scope} feature" --allow-empty >/dev/null 2>&1
  done
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.category == "scope-gap")) | length > 0'
}

# --- Edge cases ---

@test "empty repo produces empty suggestions" {
  make_profile
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 0 ]
}

@test "missing --profile fails" {
  run bash "$SUGGEST" --target "$REPO"
  [ "$status" -ne 0 ]
}

@test "missing --target fails" {
  make_profile
  run bash "$SUGGEST" --profile "$PROFILE"
  [ "$status" -ne 0 ]
}

@test "output is valid JSON array" {
  make_profile
  run bash "$SUGGEST" --profile "$PROFILE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array"'
}
