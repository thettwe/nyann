#!/usr/bin/env bats
# bin/pre-action-guard.sh + bin/guards/*.sh — per-flow precondition checks.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-guards.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

@test "commit flow: passes when files are staged and no conflict markers" {
  echo "hi" > "$REPO/a.txt"
  ( cd "$REPO" && git add a.txt )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.flow == "commit"'
}

@test "commit flow: fails critical when nothing is staged" {
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.pass == false'
  echo "$output" | jq -e '.guards[] | select(.name == "staged-files-exist") | .pass == false'
}

@test "commit flow: detects merge conflict markers in staged diff" {
  cat > "$REPO/c.txt" <<'EOF'
hello
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> branch
EOF
  ( cd "$REPO" && git add c.txt )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.guards[] | select(.name == "merge-conflict-markers") | .pass == false'
}

@test "pr flow: warns advisory when branch has no upstream" {
  echo x > "$REPO/x.txt"
  ( cd "$REPO" && git add x.txt && git commit -q -m "feat: x" )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow pr --target "$REPO"
  # No upstream → advisory failure. Exit 0 (advisory does not block).
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.guards[] | select(.name == "branch-pushed") | .pass == false'
}

@test "pr flow: catches WIP commit messages" {
  ( cd "$REPO" && git checkout -q -b feature/work \
      && git commit -q --allow-empty -m "WIP: in progress" )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow pr --target "$REPO" --base main
  echo "$output" | jq -e '.guards[] | select(.name == "wip-commits") | .pass == false'
}

@test "release flow: dirty tree blocks critical" {
  echo y > "$REPO/y.txt"
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow release --target "$REPO"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.guards[] | select(.name == "clean-tree") | .pass == false'
}

@test "release flow: clean tree passes" {
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow release --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
}

@test "unknown flow rejected" {
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow=bogus --target "$REPO"
  [ "$status" -ne 0 ]
}

@test "profile.guards subset restricts which guards run" {
  echo z > "$REPO/z.txt"
  ( cd "$REPO" && git add z.txt )
  # Profile that only declares one guard (subset semantics).
  profile="$TMP/profile.json"
  jq -n '{guards: {commit: [{name: "staged-files-exist"}]}}' > "$profile"
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO" --profile "$profile"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.guards | length')
  [ "$count" -eq 1 ]
}

@test "profile-promoted severity escalates a guard" {
  profile="$TMP/profile.json"
  jq -n '{guards: {pr: [{name: "wip-commits", severity: "critical"}]}}' > "$profile"
  ( cd "$REPO" && git checkout -q -b feature/x \
      && git commit -q --allow-empty -m "WIP: foo" )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow pr --target "$REPO" --base main --profile "$profile"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.guards[] | select(.name == "wip-commits") | .severity == "critical"'
}

@test "profile cannot demote a built-in critical guard" {
  # staged-files-exist is built-in critical. A profile that tries to weaken
  # it to advisory must be ignored — a misconfigured profile should never be
  # able to silently disarm a hard block.
  profile="$TMP/profile.json"
  jq -n '{guards: {commit: [{name: "staged-files-exist", severity: "advisory"}]}}' > "$profile"
  # Nothing staged → guard fails. With the demotion guard, severity stays
  # critical and the flow blocks (exit 3) rather than passing as advisory.
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO" --profile "$profile"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.guards[] | select(.name == "staged-files-exist") | .severity == "critical"'
}

@test "commit flow: bare ======= line (e.g. RST/changelog) does not block" {
  # A doc file with a bare `=======` underline must not be mistaken for a
  # merge-conflict separator — without a `<<<<<<< ` start marker it is benign.
  cat > "$REPO/doc.rst" <<'EOF'
Section Title
=======
body text
EOF
  ( cd "$REPO" && git add doc.rst )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.guards[] | select(.name == "merge-conflict-markers") | .pass == true'
}

@test "commit flow: real <<<<<<< conflict marker blocks" {
  cat > "$REPO/c.txt" <<'EOF'
hello
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> branch
EOF
  ( cd "$REPO" && git add c.txt )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.guards[] | select(.name == "merge-conflict-markers") | .pass == false'
}

@test "release flow: clean-tree skips (not passes) in a non-git dir" {
  nonrepo="$TMP/plain"
  mkdir -p "$nonrepo"
  run bash "$REPO_ROOT/bin/guards/clean-tree.sh" "$nonrepo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped == true'
}

@test "guard-result JSON validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  echo a > "$REPO/a.txt"
  ( cd "$REPO" && git add a.txt )
  bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO" > "$TMP/result.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/guard-result.schema.json" "$TMP/result.json"
}
