#!/usr/bin/env bats
# Tests for bin/session-check.sh — session-start drift monitor script.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SESSION_CHECK="${REPO_ROOT}/bin/session-check.sh"
  TMP=$(mktemp -d -t nyann-sesscheck.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  USER_ROOT="$TMP/nyann-home"
}

teardown() { rm -rf "$TMP"; }

@test "exits silently when no preferences.json exists" {
  mkdir -p "$USER_ROOT"
  # No preferences.json → exit 0 with no output.
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "exits silently when not in a git repo" {
  mkdir -p "$USER_ROOT"
  echo '{"default_profile":"default"}' > "$USER_ROOT/preferences.json"
  # Run in a non-git directory.
  cd "$TMP"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notification format includes profile name and action hint" {
  # Use legacy fixture which always has drift against nextjs-prototype.
  FIXTURE="${REPO_ROOT}/tests/fixtures/legacy-with-drift"
  REPO="$TMP/format-repo"
  cp -R "$FIXTURE" "$REPO"
  if [[ -f "$REPO/seed.sh" ]]; then
    ( cd "$REPO" && bash seed.sh 2>/dev/null )
  else
    ( cd "$REPO" && git init -q -b main && \
      git -c user.email=test@test.com -c user.name=test \
      commit -q --allow-empty -m "initial" )
  fi

  mkdir -p "$USER_ROOT"
  echo '{"default_profile":"nextjs-prototype"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  # Verify format: [nyann] drift detected vs '<profile>' profile: ... /nyann:retrofit
  [[ "$output" == *"'nextjs-prototype' profile"* ]]
  [[ "$output" == *"missing"* ]]
}

@test "emits notification when repo has drift" {
  # Use the legacy-with-drift fixture which has known missing files.
  FIXTURE="${REPO_ROOT}/tests/fixtures/legacy-with-drift"
  REPO="$TMP/drift-repo"
  cp -R "$FIXTURE" "$REPO"

  # Seed git history (the fixture provides seed.sh).
  if [[ -f "$REPO/seed.sh" ]]; then
    ( cd "$REPO" && bash seed.sh 2>/dev/null )
  else
    ( cd "$REPO" && git init -q -b main && \
      git -c user.email=test@test.com -c user.name=test \
      commit -q --allow-empty -m "initial" )
  fi

  mkdir -p "$USER_ROOT"
  echo '{"default_profile":"nextjs-prototype"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[nyann]"* ]]
  [[ "$output" == *"drift detected"* ]]
  [[ "$output" == *"/nyann:retrofit"* ]]
}

# ---- merged-branch cleanup nudge ----------------------------------------
# session-check.sh probes check-stale-branches.sh and elevates the
# merged-branch count into a top-level nudge when it exceeds
# NYANN_MERGED_BRANCH_THRESHOLD (default 3). Two flavors:
#   - drift + merged → fold cleanup CTA into the existing drift line
#   - merged only    → emit a "hygiene" line so the user still sees it
# Below threshold, the merged count is silent.

# Seed a repo with N merged-into-main local branches. Each branch is
# created off main, then merge-fast-forward-style: we tag a no-op
# branch off main (its tip is reachable from main, satisfying
# `merge-base --is-ancestor`).
seed_merged_branches() {
  local repo="$1"
  local n="$2"
  ( cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    for i in $(seq 1 "$n"); do
      git -c user.email=t@t -c user.name=t branch "merged-$i"
    done
    # Stay on main so check-stale-branches doesn't skip the current branch.
  )
}

@test "merged-branch nudge: count >= threshold (no other drift) emits hygiene line" {
  REPO="$TMP/clean-repo"
  mkdir -p "$REPO" "$USER_ROOT/profiles"
  seed_merged_branches "$REPO" 4
  # Use a minimal profile that expects nothing so drift_total stays 0.
  cat > "$USER_ROOT/profiles/bare-test.json" <<'PROF'
{"name":"bare-test","schemaVersion":1,"stack":{"primary_language":"unknown"},"branching":{"strategy":"github-flow","base_branches":["main"]},"conventions":{"commit_format":"conventional-commits"},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"extras":{"gitignore":false,"editorconfig":false,"claude_md":false,"github_actions_ci":false,"commit_message_template":false,"github_templates":false},"documentation":{"scaffold_types":[],"storage_strategy":"local","preferred_mcp":null,"adr_format":"madr","claude_md_mode":"router","claude_md_size_budget_kb":3,"staleness_days":null,"enable_drift_checks":{"broken_internal_links":false,"broken_mcp_links":false,"orphans":false,"staleness":false}}}
PROF
  echo '{"default_profile":"bare-test"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run env NYANN_MERGED_BRANCH_THRESHOLD=3 bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "hygiene"
  echo "$output" | grep -qF "4 merged branches"
  echo "$output" | grep -qF "/nyann:cleanup-branches"
}

@test "merged-branch nudge: count below threshold does NOT trigger cleanup CTA" {
  # A bare repo against the default profile has unrelated drift, so we
  # can't assert silence — but we can assert the merged-branch nudge
  # specifically did not fire. 2 merged branches with the default
  # threshold (3) means no "/nyann:cleanup-branches" suggestion.
  REPO="$TMP/quiet-repo"
  mkdir -p "$REPO" "$USER_ROOT"
  seed_merged_branches "$REPO" 2  # under default threshold of 3
  echo '{"default_profile":"default"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"merged branches"* ]]
  [[ "$output" != *"/nyann:cleanup-branches"* ]]
}

@test "merged-branch nudge: drift + merged folds cleanup CTA into the same line" {
  FIXTURE="${REPO_ROOT}/tests/fixtures/legacy-with-drift"
  REPO="$TMP/drift-and-merged"
  cp -R "$FIXTURE" "$REPO"
  if [[ -f "$REPO/seed.sh" ]]; then
    ( cd "$REPO" && bash seed.sh 2>/dev/null )
  fi
  # Add merged branches on top of the seeded fixture.
  ( cd "$REPO"
    for i in 1 2 3 4; do
      git -c user.email=t@t -c user.name=t branch "merged-$i" 2>/dev/null
    done
  )

  mkdir -p "$USER_ROOT"
  echo '{"default_profile":"nextjs-prototype"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run env NYANN_MERGED_BRANCH_THRESHOLD=3 bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  # Single line. Both retrofit + cleanup-branches CTAs present.
  [[ "$output" == *"drift detected"* ]]
  [[ "$output" == *"/nyann:retrofit"* ]]
  [[ "$output" == *"/nyann:cleanup-branches"* ]]
  [[ "$output" == *"merged branches"* ]]
  # Exactly one line of output (no double-ping).
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  [ "$line_count" = "1" ]
}

@test "merged-branch nudge: NYANN_MERGED_BRANCH_THRESHOLD overrides default" {
  # 4 merged branches; bumping threshold to 10 should suppress the
  # cleanup CTA (4 < 10). Other drift may still trigger the drift
  # line — we assert only that the merged-branch portion is absent.
  REPO="$TMP/threshold-repo"
  mkdir -p "$REPO" "$USER_ROOT"
  seed_merged_branches "$REPO" 4
  echo '{"default_profile":"default"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run env NYANN_MERGED_BRANCH_THRESHOLD=10 bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"merged branches"* ]]
  [[ "$output" != *"/nyann:cleanup-branches"* ]]
}

@test "merged-branch nudge: garbage env var falls back to default 3" {
  REPO="$TMP/badenv-repo"
  mkdir -p "$REPO" "$USER_ROOT"
  seed_merged_branches "$REPO" 5
  echo '{"default_profile":"default"}' > "$USER_ROOT/preferences.json"

  cd "$REPO"
  run env NYANN_MERGED_BRANCH_THRESHOLD="not-a-number" bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
  # 5 >= 3 (default after the parse fails), so the nudge fires.
  [[ "$output" == *"5 merged branches"* ]]
}

@test "resolves profile from CLAUDE.md markers when preferences say auto-detect" {
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$USER_ROOT"
  ( cd "$REPO" && git init -q -b main && \
    git -c user.email=test@test.com -c user.name=test \
    commit -q --allow-empty -m "chore: seed" )

  # Preferences with auto-detect.
  echo '{"default_profile":"auto-detect"}' > "$USER_ROOT/preferences.json"

  # CLAUDE.md with a profile marker.
  cat > "$REPO/CLAUDE.md" <<'MD'
<!-- nyann:start -->
| Profile | nextjs-prototype |
<!-- nyann:end -->
MD

  cd "$REPO"
  # Should run without error (profile resolved from CLAUDE.md).
  run bash "$SESSION_CHECK" --user-root "$USER_ROOT"
  [ "$status" -eq 0 ]
}
