#!/usr/bin/env bats
# v1.6.0 drift-check dedup: bin/session-check.sh accepts --flow=<verb>
# so the four caller skills (commit/release/pr/ship) can drop the
# duplicated drift-check preamble. When --flow is set, the emitted
# message includes a flow-specific suffix; when unset, behaviour is
# unchanged for non-skill callers (CI, monitor scripts).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SESSION_CHECK="${REPO_ROOT}/bin/session-check.sh"
  TMP=$(mktemp -d -t nyann-flow.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  USER_ROOT="$TMP/nyann-home"

  # Seed a known-drift repo via the legacy fixture.
  FIXTURE="${REPO_ROOT}/tests/fixtures/legacy-with-drift"
  REPO="$TMP/drift-repo"
  cp -R "$FIXTURE" "$REPO"
  if [[ -f "$REPO/seed.sh" ]]; then
    ( cd "$REPO" && bash seed.sh 2>/dev/null )
  fi
  mkdir -p "$USER_ROOT"
  echo '{"default_profile":"nextjs-prototype"}' > "$USER_ROOT/preferences.json"
}

teardown() { rm -rf "$TMP"; }

@test "--flow=commit appends commit-flow suffix to drift message" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift detected"* ]]
  [[ "$output" == *"non-blocking"* ]]
  [[ "$output" == *"commit flow"* ]]
}

@test "--flow=release uses release verb in suffix" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=release
  [ "$status" -eq 0 ]
  [[ "$output" == *"release flow"* ]]
  [[ "$output" != *"commit flow"* ]]
}

@test "--flow=pr uses uppercase PR in suffix (not 'pr flow')" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR flow"* ]]
  [[ "$output" != *"pr flow"* ]]
}

@test "--flow=ship uses ship verb in suffix" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=ship
  [ "$status" -eq 0 ]
  [[ "$output" == *"ship flow"* ]]
}

@test "--flow with space-separated value also works" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"commit flow"* ]]
}

@test "no --flow → message lacks flow suffix (non-skill callers unchanged)" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift detected"* ]]
  [[ "$output" != *"non-blocking"* ]]
  [[ "$output" != *"flow."* ]]
}

@test "unknown --flow value rejected with rc 2 and stderr error" {
  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=commits
  [ "$status" -eq 2 ]
  [[ "$output" == *"not one of commit"* ]] || [[ "$stderr" == *"not one of commit"* ]]
}

@test "--flow=commit with no drift exits silently (no spurious suffix)" {
  # Use a clean bare repo against a profile that expects nothing.
  CLEAN="$TMP/clean-repo"
  mkdir -p "$CLEAN" "$USER_ROOT/profiles"
  ( cd "$CLEAN" && git init -q -b main && \
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  cat > "$USER_ROOT/profiles/bare-flow-test.json" <<'PROF'
{"name":"bare-flow-test","schemaVersion":1,"stack":{"primary_language":"unknown"},"branching":{"strategy":"github-flow","base_branches":["main"]},"conventions":{"commit_format":"conventional-commits"},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"extras":{"gitignore":false,"editorconfig":false,"claude_md":false,"github_actions_ci":false,"commit_message_template":false,"github_templates":false},"documentation":{"scaffold_types":[],"storage_strategy":"local","preferred_mcp":null,"adr_format":"madr","claude_md_mode":"router","claude_md_size_budget_kb":3,"staleness_days":null,"enable_drift_checks":{"broken_internal_links":false,"broken_mcp_links":false,"orphans":false,"staleness":false}}}
PROF
  echo '{"default_profile":"bare-flow-test"}' > "$USER_ROOT/preferences.json"
  cd "$CLEAN"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--flow=ship folds with merged-branch cleanup nudge" {
  # Add merged branches on top of the drift fixture.
  ( cd "$REPO"
    for i in 1 2 3 4; do
      git -c user.email=t@t -c user.name=t branch "merged-$i" 2>/dev/null
    done
  )
  cd "$REPO"
  run env NYANN_MERGED_BRANCH_THRESHOLD=3 bash "$SESSION_CHECK" --user-root "$USER_ROOT" --flow=ship
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift detected"* ]]
  [[ "$output" == *"merged branches"* ]]
  [[ "$output" == *"ship flow"* ]]
  # Exactly one line — no double-ping.
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$line_count" = "1" ]
}
