#!/usr/bin/env bats
# bin/bootstrap.sh — scaffold-docs and gen-claudemd are only invoked
# when the ActionPlan declares the corresponding writes. Same
# preview-before-mutate invariant that gates .editorconfig (see
# test-bootstrap-editorconfig.bats).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  TMP=$(mktemp -d -t nyann-prevgate.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  PROFILE="${REPO_ROOT}/profiles/typescript-library.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$PROFILE" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
}

teardown() { rm -rf "$TMP"; }

# Compute the canonical SHA-256 of a plan file the way bootstrap expects.
plan_sha() { bash "$PREVIEW" --plan "$1" --emit-sha256 2>/dev/null; }

# ---- CLAUDE.md gating ------------------------------------------------------

@test "CLAUDE.md NOT written when absent from plan writes[]" {
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/CLAUDE.md" ]
  echo "$output" | grep -Fq "CLAUDE.md is not in the ActionPlan"
}

@test "CLAUDE.md IS written when declared in plan writes[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -f "$REPO/CLAUDE.md" ]
  grep -Fq '<!-- nyann:start -->' "$REPO/CLAUDE.md"
}

@test "profile claude_md_mode=off suppresses gen-claudemd even when plan declares it" {
  # Copy the profile and tweak claude_md_mode → off.
  profile_off="$TMP/profile-off.json"
  jq '.documentation.claude_md_mode = "off"' "$PROFILE" > "$profile_off"

  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$profile_off" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/CLAUDE.md" ]
  echo "$output" | grep -Fq "claude_md_mode=off"
}

# ---- docs scaffolding gating -----------------------------------------------

@test "scaffold-docs skipped when plan declares no docs/ or memory/ entries" {
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -d "$REPO/docs" ]
  # memory/.nyann/ is created by the boot-record subsystem (always);
  # scaffold-docs's marker is memory/README.md — that's what should be absent.
  [ ! -f "$REPO/memory/README.md" ]
  echo "$output" | grep -Fq "scaffold-docs"
  echo "$output" | grep -Fq "ActionPlan"
}

@test "scaffold-docs runs when plan includes docs/ entries" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[
  {"path":"docs/architecture.md","action":"create","bytes":0},
  {"path":"memory/README.md","action":"create","bytes":0}
],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -d "$REPO/docs" ]
  [ -f "$REPO/docs/README.md" ]  || [ -f "$REPO/docs/architecture.md" ]
}

@test "workspace .gitignore NOT written when absent from plan writes[] (Codex regression)" {
  # Regression guard: bootstrap step 5b used to unconditionally write per-
  # workspace .gitignore for every workspace whose extras.gitignore=true.
  # A buggy/older plan that omits those paths would leak workspace writes
  # the operator never previewed. Now gated on plan.writes[].
  monorepo_profile="$TMP/profile-monorepo.json"
  jq '. + {workspaces: {"packages/api": {extras: {gitignore: true}}}}' \
    "$PROFILE" > "$monorepo_profile"
  cat > "$TMP/stack.json" <<'EOF'
{"primary_language":"typescript","secondary_languages":[],"is_monorepo":true,"monorepo_tool":"pnpm-workspaces",
 "workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"}]}
EOF
  mkdir -p "$REPO/packages/api"
  # Plan deliberately OMITS packages/api/.gitignore.
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$monorepo_profile" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/packages/api/.gitignore" ]
  echo "$output" | grep -Fq "skipping workspace gitignore"
  echo "$output" | grep -Fq "packages/api/.gitignore"
}

@test "workspace .gitignore IS written when declared in plan writes[] (Codex regression)" {
  monorepo_profile="$TMP/profile-monorepo.json"
  jq '. + {workspaces: {"packages/api": {extras: {gitignore: true}}}}' \
    "$PROFILE" > "$monorepo_profile"
  cat > "$TMP/stack.json" <<'EOF'
{"primary_language":"typescript","secondary_languages":[],"is_monorepo":true,"monorepo_tool":"pnpm-workspaces",
 "workspaces":[{"path":"packages/api","primary_language":"python","framework":null,"package_manager":"pip"}]}
EOF
  mkdir -p "$REPO/packages/api"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[
  {"path":"packages/api/.gitignore","action":"create","bytes":0}
],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$monorepo_profile" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -f "$REPO/packages/api/.gitignore" ]
}

@test "scaffold-docs runs when plan declares ONLY workspace-nested doc writes (Codex regression)" {
  # Regression guard: the docs_in_plan gate used to count only root-level
  # docs/ + memory/ entries. A monorepo whose root profile has no docs but
  # a workspace profile does would show workspace doc writes in preview
  # and then silently skip scaffold-docs at execution time. The gate now
  # recognizes nested workspace paths too.
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[
  {"path":"packages/api/docs/architecture.md","action":"create","bytes":0}
],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  # Even though we don't pass --workspace-configs in this minimal harness,
  # the gate must NOT short-circuit before reaching scaffold-docs.sh. The
  # surest signal is the absence of the skip-warn in stderr.
  ! echo "$output" | grep -Fq "skipping scaffold-docs"
}

# ---- remote[] gate ---------------------------------------------------------
# preview.sh renders ActionPlan.remote[] but bootstrap has no dispatcher
# yet. Silently dropping the entries would lie to preview-before-mutate
# (the user saw branch-protection rules in preview and now they aren't
# being applied). Bootstrap must refuse the plan instead.

@test "bootstrap refuses a plan with non-empty remote[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[
  {"type":"branch_protection","branch":"main","rules":{"require_pr":true}}
]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "remote[]"
  echo "$output" | grep -Fq "no remote dispatcher"
  # Pointer to the sanctioned tool for the supported case.
  echo "$output" | grep -Fq "gh-integration.sh"
}

@test "bootstrap accepts a plan with empty remote[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
}

# ---- symlink refusal on preview_blob cp paths ------------------------------
# Regression: the .gitignore and CLAUDE.md cp-from-blob paths lacked the
# symlink guard the .editorconfig path has. A pre-planted symlink at the
# destination would let cp write through it, escaping the target.

@test "symlinked .gitignore destination is refused, not written through" {
  # Pre-plant a symlink pointing outside the repo.
  outside="$TMP/outside-gitignore"
  echo "ORIGINAL-OUTSIDE" > "$outside"
  ln -s "$outside" "$REPO/.gitignore"
  # Blob the plan's preview_blob points to.
  blob="$TMP/gi-blob"
  echo "node_modules" > "$blob"
  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":".gitignore","action":"merge","bytes":0,"preview_blob":"$blob","current_bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "refusing to write .gitignore via symlink"
  # The file outside the repo must be untouched.
  [ "$(cat "$outside")" = "ORIGINAL-OUTSIDE" ]
}

@test "symlinked CLAUDE.md destination is refused, not written through" {
  outside="$TMP/outside-claude"
  echo "ORIGINAL-OUTSIDE" > "$outside"
  ln -s "$outside" "$REPO/CLAUDE.md"
  blob="$TMP/cm-blob"
  echo "# nyann router" > "$blob"
  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":"CLAUDE.md","action":"merge","bytes":0,"preview_blob":"$blob","current_bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "refusing to write CLAUDE.md via symlink"
  [ "$(cat "$outside")" = "ORIGINAL-OUTSIDE" ]
}
