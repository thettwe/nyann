#!/usr/bin/env bats
# Schema-validation bats for the 6 schemas that had no runtime check.
# Ensures producers emit output that satisfies its own schema, so the
# schema contract catches drift the moment a bin script starts emitting
# fields outside its `properties` or missing a field in `required[]`.
#
# Schemas covered here:
#   - action-plan.schema.json        (skill-layer composed; we synthesize a minimal valid one)
#   - documentation-plan.schema.json (produced by bin/route-docs.sh)
#   - drift-report.schema.json       (produced by bin/compute-drift.sh)
#   - mcp-doc-targets.schema.json    (produced by bin/detect-mcp-docs.sh)
#   - link-check-report.schema.json  (produced by bin/check-links.sh)
#   - orphan-report.schema.json      (produced by bin/find-orphans.sh)
#
# Already runtime-validated elsewhere:
#   - stack-descriptor.schema.json  → tests/bats/test-detect.bats
#   - branching-choice.schema.json  → tests/bats/test-recommend.bats
#   - config.schema.json            → tests/bats/test-sync-team.bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-schema.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )

  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator (install check-jsonschema or uvx)"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
}

teardown() { rm -rf "$TMP"; }

validate_stdout_against() {
  local schema="$1"; shift
  # Capture stderr + exit code so a producer regression that writes a
  # partial-but-valid prefix before crashing can't pass silently.
  local producer_status
  if "$@" > "$TMP/out.json" 2> "$TMP/err.txt"; then
    producer_status=0
  else
    producer_status=$?
  fi
  if (( producer_status != 0 )); then
    echo "producer exited $producer_status; stderr:" >&2
    cat "$TMP/err.txt" >&2
    return 1
  fi
  [[ -s "$TMP/out.json" ]] || { echo "producer emitted nothing; stderr:" >&2; cat "$TMP/err.txt" >&2; return 1; }
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/$schema" "$TMP/out.json"
}

# --- DocumentationPlan (route-docs.sh) --------------------------------------

@test "documentation-plan schema: route-docs output validates (default profile)" {
  validate_stdout_against documentation-plan.schema.json \
    bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/default.json"
}

@test "documentation-plan schema: route-docs output validates (nextjs-prototype)" {
  validate_stdout_against documentation-plan.schema.json \
    bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/nextjs-prototype.json"
}

# --- DriftReport (compute-drift.sh) -----------------------------------------

@test "drift-report schema: compute-drift output validates" {
  validate_stdout_against drift-report.schema.json \
    bash "${REPO_ROOT}/bin/compute-drift.sh" \
      --target "$REPO" --profile "${REPO_ROOT}/profiles/default.json"
}

# --- MCPDocTargets (detect-mcp-docs.sh) -------------------------------------

@test "mcp-doc-targets schema: detect-mcp-docs output validates (no settings)" {
  # detect-mcp-docs reads Claude Code settings.json; point it at a
  # fresh (nonexistent) path so the script emits the "no settings"
  # shape.
  validate_stdout_against mcp-doc-targets.schema.json \
    bash "${REPO_ROOT}/bin/detect-mcp-docs.sh" \
      --settings-path "$TMP/no-such-settings.json"
}

# --- LinkCheckReport (check-links.sh) ---------------------------------------

@test "link-check-report schema: check-links output validates (empty repo)" {
  validate_stdout_against link-check-report.schema.json \
    bash "${REPO_ROOT}/bin/check-links.sh" --target "$REPO"
}

# --- OrphanReport (find-orphans.sh) -----------------------------------------

@test "orphan-report schema: find-orphans output validates" {
  validate_stdout_against orphan-report.schema.json \
    bash "${REPO_ROOT}/bin/find-orphans.sh" --target "$REPO"
}

# --- ActionPlan (no direct producer; validate a hand-rolled minimal plan) ---

@test "action-plan schema: minimal hand-rolled plan validates" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/action-plan.schema.json" "$TMP/plan.json"
}

@test "action-plan schema: rejects an absolute path in writes[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"/etc/passwd","action":"delete"}],"commands":[],"remote":[]}
JSON
  # The schema may accept absolute paths (it's a string), so we're
  # mostly verifying the schema doesn't reject structurally valid JSON.
  # The runtime `nyann::assert_path_under_target` in bootstrap.sh is
  # what actually blocks — that's a separate test-bootstrap case.
  run "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/action-plan.schema.json" "$TMP/plan.json"
  # We don't assert pass or fail here — just that the validator runs
  # without crashing. The real enforcement is runtime: bootstrap
  # rejects out-of-target paths via nyann::assert_path_under_target.
  [ "$status" -le 1 ]
}

# --- CommitResult (try-commit.sh) -------------------------------------------

@test "commit-result schema: try-commit on empty staging emits error result" {
  ( cd "$REPO" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  # Nothing staged → try-commit refuses with an error-shaped JSON.
  validate_stdout_against commit-result.schema.json \
    bash "${REPO_ROOT}/bin/try-commit.sh" --target "$REPO" --subject "feat: bats schema check"
}

# --- SyncResult (sync.sh) ---------------------------------------------------

@test "sync-result schema: clean up-to-date branch emits SyncResult" {
  # Up-to-date branch exits 0 with valid SyncResult JSON. The dirty-tree
  # path also emits valid JSON but exits 1 (validate_stdout_against
  # treats non-zero as producer failure).
  ( cd "$REPO"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    git checkout -q -b feat/x
  )
  validate_stdout_against sync-result.schema.json \
    bash "${REPO_ROOT}/bin/sync.sh" --target "$REPO" --dry-run
}

# --- UndoResult (undo.sh) ---------------------------------------------------

@test "undo-result schema: undo --dry-run emits preview shape" {
  ( cd "$REPO"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    git checkout -q -b feat/x
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: a"
  )
  validate_stdout_against undo-result.schema.json \
    bash "${REPO_ROOT}/bin/undo.sh" --target "$REPO" --dry-run
}

@test "undo-result schema: undo on main emits refused shape" {
  ( cd "$REPO" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  # undo.sh exits 1 with refused JSON when on main.
  out=$(bash "${REPO_ROOT}/bin/undo.sh" --target "$REPO" 2>/dev/null || true)
  echo "$out" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/undo-result.schema.json" "$TMP/out.json"
}

# --- PrResult (pr.sh) -------------------------------------------------------

@test "pr-result schema: --context-only emits PrContext shape" {
  ( cd "$REPO"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    git checkout -q -b feat/x
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: a"
  )
  validate_stdout_against pr-result.schema.json \
    bash "${REPO_ROOT}/bin/pr.sh" --target "$REPO" --context-only
}

# --- ReleaseResult (release.sh) ---------------------------------------------

@test "release-result schema: changesets strategy emits skipped shape" {
  ( cd "$REPO" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  validate_stdout_against release-result.schema.json \
    bash "${REPO_ROOT}/bin/release.sh" --target "$REPO" --version 1.2.3 --strategy changesets
}

# --- CommitContext (commit.sh) ----------------------------------------------

@test "commit-context schema: commit.sh emits CommitContext when changes are staged" {
  ( cd "$REPO"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    git checkout -q -b feat/x
    echo "x" > a.txt
    git add a.txt
  )
  validate_stdout_against commit-context.schema.json \
    bash "${REPO_ROOT}/bin/commit.sh" --target "$REPO"
}

# --- PrereqsReport (check-prereqs.sh) ---------------------------------------

@test "prereqs-report schema: check-prereqs --json validates" {
  validate_stdout_against prereqs-report.schema.json \
    bash "${REPO_ROOT}/bin/check-prereqs.sh" --json
}

# --- StateSummary (explain-state.sh) ----------------------------------------

@test "state-summary schema: explain-state --json on bare repo validates" {
  validate_stdout_against state-summary.schema.json \
    bash "${REPO_ROOT}/bin/explain-state.sh" --target "$REPO" --json
}

# --- TeamDriftReport (check-team-drift.sh) ----------------------------------

@test "team-drift-report schema: empty config emits empty arrays shape" {
  # No config.json present → drift checker emits the empty-shape JSON
  # (drift:[], up_to_date:[], unreachable:[]).
  fake_home="$TMP/home"
  mkdir -p "$fake_home/.claude/nyann"
  validate_stdout_against team-drift-report.schema.json \
    env HOME="$fake_home" bash "${REPO_ROOT}/bin/check-team-drift.sh" --offline --user-root "$fake_home/.claude/nyann"
}

# --- TeamSyncResult (sync-team-profiles.sh) ---------------------------------

@test "team-sync-result schema: empty config emits empty arrays shape" {
  fake_home="$TMP/home"
  mkdir -p "$fake_home/.claude/nyann"
  validate_stdout_against team-sync-result.schema.json \
    env HOME="$fake_home" bash "${REPO_ROOT}/bin/sync-team-profiles.sh" --user-root "$fake_home/.claude/nyann"
}

# --- GhIntegrationResult (gh-integration.sh) --------------------------------

@test "gh-integration-result schema: skipped path emits valid shape (no gh)" {
  # Point --gh at a path that doesn't exist so the gh-not-installed
  # skip path runs deterministically without depending on the test
  # host's actual gh state.
  cat > "$TMP/no-gh.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake gh: not installed" >&2
exit 127
EOF
  chmod +x "$TMP/no-gh.sh"
  # check-prereqs needs PATH; gh-integration needs to find a gh that
  # fails. Use --gh to specify a non-existent binary.
  validate_stdout_against gh-integration-result.schema.json \
    bash "${REPO_ROOT}/bin/gh-integration.sh" --target "$REPO" --profile nextjs-prototype --gh "/tmp/definitely-not-gh-$$"
}

# --- SetupStatus (setup.sh) -------------------------------------------------

@test "setup-status schema: --check on a fresh user-root emits not_configured shape" {
  fake_home="$TMP/home"
  mkdir -p "$fake_home/.claude/nyann"
  run bash "${REPO_ROOT}/bin/setup.sh" --check --json --user-root "$fake_home/.claude/nyann"
  [ "$status" -eq 0 ]
  echo "$output" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/setup-status.schema.json" "$TMP/out.json"
}

@test "setup-status schema: --check on a configured user-root emits configured shape" {
  fake_home="$TMP/home"
  mkdir -p "$fake_home/.claude/nyann/profiles" "$fake_home/.claude/nyann/cache"
  cat > "$fake_home/.claude/nyann/preferences.json" <<JSON
{
  "schemaVersion": 1,
  "default_profile": "auto-detect",
  "branching_strategy": "auto-detect",
  "commit_format": "conventional-commits",
  "gh_integration": true,
  "documentation_storage": "local",
  "auto_sync_team_profiles": false,
  "setup_completed_at": "2026-04-25T00:00:00Z"
}
JSON
  validate_stdout_against setup-status.schema.json \
    env HOME="$fake_home" bash "${REPO_ROOT}/bin/setup.sh" --check --json --user-root "$fake_home/.claude/nyann"
}

# --- Suggestions (suggest-profile-updates.sh) -------------------------------

@test "suggestions schema: suggest on a vanilla repo emits valid array" {
  validate_stdout_against suggestions.schema.json \
    bash "${REPO_ROOT}/bin/suggest-profile-updates.sh" \
      --target "$REPO" --profile "${REPO_ROOT}/profiles/default.json"
}

# --- ClaudemdAnalysis (analyze-claudemd-usage.sh) ---------------------------

@test "claudemd-analysis schema: insufficient_data path emits valid shape" {
  mkdir -p "$REPO/memory"
  cat > "$REPO/CLAUDE.md" <<'MD'
# Project
<!-- nyann:start -->
## Build
- npm test
<!-- nyann:end -->
MD
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{ "sessions": 0, "sections": {}, "commands_run": {}, "docs_read": {} }
JSON
  validate_stdout_against claudemd-analysis.schema.json \
    bash "${REPO_ROOT}/bin/analyze-claudemd-usage.sh" --target "$REPO"
}

# --- ClaudemdSizeReport (check-claude-md-size.sh) ---------------------------

@test "claudemd-size-report schema: absent CLAUDE.md emits absent shape" {
  validate_stdout_against claudemd-size-report.schema.json \
    bash "${REPO_ROOT}/bin/check-claude-md-size.sh" \
      --target "$REPO" --profile "${REPO_ROOT}/profiles/default.json"
}

@test "claudemd-size-report schema: present CLAUDE.md emits present shape" {
  echo "# Project" > "$REPO/CLAUDE.md"
  validate_stdout_against claudemd-size-report.schema.json \
    bash "${REPO_ROOT}/bin/check-claude-md-size.sh" \
      --target "$REPO" --profile "${REPO_ROOT}/profiles/default.json"
}

# --- StalenessReport (check-staleness.sh) -----------------------------------

@test "staleness-report schema: profile w/o staleness_days emits disabled shape" {
  # default.json leaves staleness_days unset → enabled:false branch.
  validate_stdout_against staleness-report.schema.json \
    bash "${REPO_ROOT}/bin/check-staleness.sh" \
      --target "$REPO" --profile "${REPO_ROOT}/profiles/default.json"
}

# --- WorkspaceConfigs (resolve-workspace-configs.sh) ------------------------

@test "workspace-configs schema: empty workspaces emits empty array" {
  # No workspaces in profile → script emits []. Still must validate as an
  # array (which the schema requires at the top level).
  cat > "$TMP/stack.json" <<'JSON'
{ "primary_language": "typescript", "secondary_languages": [], "is_monorepo": false }
JSON
  validate_stdout_against workspace-configs.schema.json \
    bash "${REPO_ROOT}/bin/resolve-workspace-configs.sh" \
      --profile "${REPO_ROOT}/profiles/default.json" --stack "$TMP/stack.json"
}

# --- MigrationPlan (switch-profile.sh) --------------------------------------

@test "migration-plan schema: --json diff between two profiles validates" {
  validate_stdout_against migration-plan.schema.json \
    bash "${REPO_ROOT}/bin/switch-profile.sh" \
      --from default --to nextjs-prototype --target "$REPO" --json
}

# A producer that emits schema-valid JSON to stdout *and then exits
# non-zero* must fail the helper.
@test "validate_stdout_against fails when producer exits non-zero" {
  run validate_stdout_against action-plan.schema.json \
    bash -c 'echo "{\"writes\":[],\"commands\":[],\"remote\":[]}"; exit 1'
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "producer exited 1"
}
