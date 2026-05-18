#!/usr/bin/env bats
# v1.9.0 (Codex review #3): scaffold-docs.sh renders workspace docs with the
# WORKSPACE's stack metadata, not the root repo's. Without this, a Python
# workspace under a TypeScript root would get TS-flavoured docs.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCAFFOLD="${REPO_ROOT}/bin/scaffold-docs.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"

  # Doc plan covers root architecture so the script doesn't no-op.
  cat > "$TMP/doc-plan.json" <<'EOF'
{
  "storage_strategy": "local",
  "targets": {
    "architecture": {"type": "local", "path": "docs/architecture.md"}
  }
}
EOF

  # Root stack is TYPESCRIPT + Next.js + pnpm.
  cat > "$TMP/stack.json" <<'EOF'
{
  "primary_language": "typescript",
  "framework": "next",
  "package_manager": "pnpm",
  "is_monorepo": true
}
EOF
}

teardown() { rm -rf "$TMP"; }

@test "workspace doc renders with workspace stack (python under typescript root)" {
  # Workspace config: packages/api is PYTHON + FastAPI + pip.
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/api",
    "primary_language": "python",
    "framework": "fastapi",
    "package_manager": "pip",
    "profile": null,
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["architecture"]}
  }
]
EOF

  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/packages/api/docs/architecture.md" ]

  # The workspace doc MUST reference python/fastapi/pip — NOT typescript/next/pnpm.
  ws_doc="$TARGET/packages/api/docs/architecture.md"
  grep -Fq "python" "$ws_doc"
  grep -Fq "fastapi" "$ws_doc"
  grep -Fq "pip" "$ws_doc"
  # Negative: root-stack values must NOT leak into the workspace doc.
  ! grep -Fq "typescript" "$ws_doc"
  ! grep -Fq "next" "$ws_doc"
  ! grep -Fq "pnpm" "$ws_doc"
}

@test "root doc still uses root stack (no leakage from workspace render)" {
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/api",
    "primary_language": "python",
    "framework": "fastapi",
    "package_manager": "pip",
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["architecture"]}
  }
]
EOF

  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/docs/architecture.md" ]

  root_doc="$TARGET/docs/architecture.md"
  grep -Fq "typescript" "$root_doc"
  grep -Fq "next" "$root_doc"
  # Workspace values must not leak back into the root doc — subshell isolation.
  ! grep -Fq "fastapi" "$root_doc"
  ! grep -Fq "python" "$root_doc"
}

@test "workspace project_name is the workspace basename, not the root" {
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/api",
    "primary_language": "python",
    "framework": null,
    "package_manager": null,
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["architecture"]}
  }
]
EOF

  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --project-name "my-monorepo" \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]

  # Workspace doc's project_name token resolves to "api" (basename), not "my-monorepo".
  ws_doc="$TARGET/packages/api/docs/architecture.md"
  grep -Fq "api" "$ws_doc"

  # Root doc gets the explicit --project-name.
  root_doc="$TARGET/docs/architecture.md"
  grep -Fq "my-monorepo" "$root_doc"
}

@test "--allowed-writes gates workspace doc writes — missing path is skipped (Codex regression)" {
  # Runtime preview-before-mutate gate: if a workspace doc target is NOT
  # in the allowed-writes list, scaffold-docs.sh must skip + warn rather
  # than materialise the file. Defends against planner/executor drift
  # where plan-bootstrap.sh and resolve-workspace-configs.sh disagree on
  # which scaffolds to enumerate.
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/api",
    "primary_language": "python",
    "framework": "fastapi",
    "package_manager": "pip",
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["architecture", "prd"]}
  }
]
EOF
  # Allow-list deliberately omits packages/api/docs/prd.md
  echo "packages/api/docs/architecture.md" > "$TMP/allowed.txt"

  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --workspace-configs "$TMP/ws-configs.json" \
    --allowed-writes "$TMP/allowed.txt"
  [ "$status" -eq 0 ]
  # Allowed path WAS written
  [ -f "$TARGET/packages/api/docs/architecture.md" ]
  # Disallowed path was NOT written
  [ ! -f "$TARGET/packages/api/docs/prd.md" ]
  # Warn was emitted for the skipped path
  echo "$output" | grep -q "skipping workspace doc"
  echo "$output" | grep -q "packages/api/docs/prd.md"
}

@test "--allowed-writes absent: back-compat — every declared scaffold is written" {
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/api",
    "primary_language": "python",
    "framework": "fastapi",
    "package_manager": "pip",
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["architecture", "prd"]}
  }
]
EOF
  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  # Without the gate, both targets are written
  [ -f "$TARGET/packages/api/docs/architecture.md" ]
  [ -f "$TARGET/packages/api/docs/prd.md" ]
}

@test "symlinked intermediate workspace doc dir is refused (path traversal guard)" {
  # Codex security finding: write_if_missing rejects leaf symlinks but
  # mkdir -p happily follows symlinks at INTERMEDIATE components. A
  # repo with a pre-placed symlink at packages/<ws>/docs/research →
  # /etc/ would otherwise redirect doc scaffolding outside the target
  # tree on `mkdir -p "$ws_doc_dir/research"` + the subsequent
  # README.md write. _ws_safe_mkdir walks every component and refuses
  # any existing symlinked ancestor.

  # Stage a "decoy target" outside the project tree. A successful
  # exploit would land workspace doc files HERE instead of in the project.
  decoy="$TMP/escape-target"
  mkdir -p "$decoy"

  # Pre-place packages/api/docs/decisions as a symlink to the decoy.
  mkdir -p "$TARGET/packages/api/docs"
  ln -s "$decoy" "$TARGET/packages/api/docs/decisions"

  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/api",
    "primary_language": "python",
    "framework": null,
    "package_manager": "pip",
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["adrs"]}
  }
]
EOF

  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]
  # The exploit would have written README.md into $decoy. Assert no escape.
  [ ! -f "$decoy/README.md" ]
  [ ! -f "$decoy/ADR-template.md" ]
  # And the script must have warned about the symlinked intermediate.
  echo "$output" | grep -q "intermediate component is a symlink"
}

@test "workspace without framework/pm renders (none) and skips conditional blocks" {
  cat > "$TMP/ws-configs.json" <<'EOF'
[
  {
    "path": "packages/lib",
    "primary_language": "rust",
    "framework": null,
    "package_manager": null,
    "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
    "extras": {},
    "documentation": {"scaffold_types": ["architecture"]}
  }
]
EOF

  run bash "$SCAFFOLD" \
    --plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" \
    --target "$TARGET" \
    --workspace-configs "$TMP/ws-configs.json"
  [ "$status" -eq 0 ]

  ws_doc="$TARGET/packages/lib/docs/architecture.md"
  grep -Fq "rust" "$ws_doc"
  # framework_or_na / package_manager_or_na render as "(none)"
  grep -Fq "(none)" "$ws_doc"
  # The {{#if framework}}...{{/if}} block stripped → no leftover "built on" prose
  ! grep -Fq "built on" "$ws_doc"
}
