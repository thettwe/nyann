#!/usr/bin/env bats
# Integration tests for monorepo-aware bootstrap flow.
# Uses the tests/fixtures/monorepo/ fixture.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
  FIXTURE="$REPO_ROOT/tests/fixtures/monorepo"
}

teardown() { rm -rf "$TMP"; }

@test "detect-stack + resolve-workspace-configs pipeline works with fixture" {
  stack=$("${REPO_ROOT}/bin/detect-stack.sh" --path "$FIXTURE" 2>/dev/null)
  echo "$stack" > "$TMP/stack.json"

  [ "$(jq -r '.is_monorepo' <<<"$stack")" = "true" ]
  [ "$(jq -r '.monorepo_tool' <<<"$stack")" = "pnpm-workspaces" ]
  [ "$(jq '.workspaces | length' <<<"$stack")" -ge 2 ]

  run bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" --profile "${REPO_ROOT}/profiles/default.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -ge 2 ]
}

@test "workspace-aware CLAUDE.md includes Workspaces table" {
  mkdir -p "$TMP/repo/.git"
  stack=$("${REPO_ROOT}/bin/detect-stack.sh" --path "$FIXTURE" 2>/dev/null)
  echo "$stack" > "$TMP/stack.json"

  "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    > "$TMP/ws-configs.json" 2>/dev/null

  echo '{"storage_strategy":"local","targets":{"memory":{"type":"local","path":"memory"}}}' \
    > "$TMP/docplan.json"

  "${REPO_ROOT}/bin/gen-claudemd.sh" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --workspace-configs "$TMP/ws-configs.json" \
    --target "$TMP/repo" \
    --project-name "test-monorepo" 2>/dev/null

  [ -f "$TMP/repo/CLAUDE.md" ]
  grep -q "## Workspaces" "$TMP/repo/CLAUDE.md"
  grep -q "packages/api" "$TMP/repo/CLAUDE.md"
  grep -q "packages/web" "$TMP/repo/CLAUDE.md"
  grep -q "Monorepo | true" "$TMP/repo/CLAUDE.md"
}

@test "workspace-aware CLAUDE.md renders scopes from workspaces" {
  mkdir -p "$TMP/repo/.git"
  stack=$("${REPO_ROOT}/bin/detect-stack.sh" --path "$FIXTURE" 2>/dev/null)
  echo "$stack" > "$TMP/stack.json"

  "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
    --stack "$TMP/stack.json" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    > "$TMP/ws-configs.json" 2>/dev/null

  # Extract workspace basenames as scopes.
  jq '[.[].path | split("/") | last]' "$TMP/ws-configs.json" > "$TMP/scopes.json"

  echo '{"storage_strategy":"local","targets":{"memory":{"type":"local","path":"memory"}}}' \
    > "$TMP/docplan.json"

  "${REPO_ROOT}/bin/gen-claudemd.sh" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --workspace-configs "$TMP/ws-configs.json" \
    --extra-scopes "$TMP/scopes.json" \
    --target "$TMP/repo" \
    --project-name "test-monorepo" 2>/dev/null

  # Scopes should appear in conventions table.
  grep -q "Commit scopes" "$TMP/repo/CLAUDE.md"
  grep -q "api" "$TMP/repo/CLAUDE.md"
  grep -q "web" "$TMP/repo/CLAUDE.md"
}

@test "workspace-aware lint-staged generates per-package globs" {
  # Set up a minimal git + node repo in TMP.
  mkdir -p "$TMP/repo/.git/hooks"
  echo '{"name":"test","private":true}' > "$TMP/repo/package.json"
  echo 'packages:\n  - packages/*' > "$TMP/repo/pnpm-workspace.yaml"
  mkdir -p "$TMP/repo/.husky/_"

  # Create workspace configs.
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"python","framework":"fastapi","package_manager":"pip",
   "hooks":{"pre_commit":["ruff","ruff-format"],"commit_msg":[],"pre_push":[]},"extras":{}},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm",
   "hooks":{"pre_commit":["eslint","prettier"],"commit_msg":[],"pre_push":[]},"extras":{}}
]
EOF

  run bash "${REPO_ROOT}/bin/install-hooks.sh" \
    --target "$TMP/repo" --jsts \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]

  # Verify per-workspace lint-staged entries in package.json.
  lint_staged=$(jq '."lint-staged"' "$TMP/repo/package.json")
  echo "$lint_staged" | jq -e '."packages/api/**/*.py"' >/dev/null
  echo "$lint_staged" | jq -e '."packages/web/**/*.{js,jsx,ts,tsx,mjs,cjs}"' >/dev/null

  # Python workspace should have ruff commands.
  api_cmds=$(echo "$lint_staged" | jq -r '."packages/api/**/*.py" | join(",")')
  [[ "$api_cmds" == *"ruff"* ]]

  # TypeScript workspace should have eslint + prettier.
  web_cmds=$(echo "$lint_staged" | jq -r '."packages/web/**/*.{js,jsx,ts,tsx,mjs,cjs}" | join(",")')
  [[ "$web_cmds" == *"eslint"* ]]
  [[ "$web_cmds" == *"prettier"* ]]
}

@test "commitlint config includes scope-enum when scopes provided" {
  mkdir -p "$TMP/repo/.git/hooks" "$TMP/repo/.husky/_"
  echo '{"name":"test","private":true}' > "$TMP/repo/package.json"
  echo '["api","web","shared"]' > "$TMP/scopes.json"

  run bash "${REPO_ROOT}/bin/install-hooks.sh" \
    --target "$TMP/repo" --jsts \
    --commit-scopes "$TMP/scopes.json"
  [ "$status" -eq 0 ]

  [ -f "$TMP/repo/commitlint.config.js" ]
  grep -q "scope-enum" "$TMP/repo/commitlint.config.js"
  grep -q '"api"' "$TMP/repo/commitlint.config.js"
  grep -q '"web"' "$TMP/repo/commitlint.config.js"
  grep -q '"shared"' "$TMP/repo/commitlint.config.js"
}

@test "without --workspace-configs, lint-staged uses generic globs (backward compat)" {
  mkdir -p "$TMP/repo/.git/hooks" "$TMP/repo/.husky/_"
  echo '{"name":"test","private":true}' > "$TMP/repo/package.json"

  run bash "${REPO_ROOT}/bin/install-hooks.sh" --target "$TMP/repo" --jsts
  [ "$status" -eq 0 ]

  lint_staged=$(jq '."lint-staged"' "$TMP/repo/package.json")
  # Should have the generic glob, not workspace-specific ones.
  echo "$lint_staged" | jq -e '."*.{js,jsx,ts,tsx,mjs,cjs}"' >/dev/null
}

@test "all starter profiles still validate after schema change" {
  for p in "${REPO_ROOT}"/profiles/*.json; do
    [[ "$(basename "$p")" == "_schema.json" ]] && continue
    run bash "${REPO_ROOT}/bin/validate-profile.sh" "$p"
    [ "$status" -eq 0 ]
  done
}
