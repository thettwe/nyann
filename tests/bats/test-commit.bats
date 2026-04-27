#!/usr/bin/env bats
# bin/commit.sh — staged-diff context gathering for the commit skill.
# This script feeds straight into the LLM prompt, so a regression in
# JSON shape, convention detection, or staged-diff truncation would
# break the commit skill silently. Direct tests lock the contract.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMMIT="${REPO_ROOT}/bin/commit.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
  )
  echo "$repo"
}

# ---- guards -----------------------------------------------------------------

@test "refuses when target is not a git repo (exit 2)" {
  run bash "$COMMIT" --target "$TMP"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "not a git repo"
}

@test "exits 0 with nothing_staged JSON when no staged changes" {
  repo=$(make_repo)
  run bash "$COMMIT" --target "$repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.nothing_staged')" = "true" ]
}

@test "rejects unknown argument" {
  repo=$(make_repo)
  run bash "$COMMIT" --target "$repo" --bogus-flag
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "unknown argument"
}

# ---- happy path: staged context ---------------------------------------------

@test "emits required JSON fields when changes are staged" {
  repo=$(make_repo)
  ( cd "$repo"
    echo "hello" > a.txt
    git add a.txt
  )
  out=$(bash "$COMMIT" --target "$repo" 2>/dev/null)
  # All schema fields the skill prompt depends on:
  for field in target branch on_main convention convention_source \
               staged_files n_files insertions deletions summary diff truncated; do
    echo "$out" | jq -e --arg f "$field" 'has($f)' >/dev/null \
      || { echo "missing field: $field" >&2; false; }
  done
  [ "$(echo "$out" | jq -r '.n_files')" = "1" ]
  [ "$(echo "$out" | jq -r '.insertions')" = "1" ]
  [ "$(echo "$out" | jq -r '.deletions')" = "0" ]
  [ "$(echo "$out" | jq -r '.staged_files[0]')" = "a.txt" ]
}

@test "on_main is true when staged on main, false otherwise" {
  repo=$(make_repo)
  ( cd "$repo"
    echo "on-main" > m.txt
    git add m.txt
  )
  out=$(bash "$COMMIT" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.on_main')" = "true" ]

  ( cd "$repo"
    git -c user.email=t@t -c user.name=t commit -q -m "chore: m"
    git checkout -q -b feat/x
    echo "feat" > f.txt
    git add f.txt
  )
  out=$(bash "$COMMIT" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.on_main')" = "false" ]
  [ "$(echo "$out" | jq -r '.branch')" = "feat/x" ]
}

# ---- convention detection ---------------------------------------------------

@test "detects commitlint.config.js → conventional-commits" {
  repo=$(make_repo)
  ( cd "$repo"
    echo "module.exports = {extends:['@commitlint/config-conventional']};" > commitlint.config.js
    echo "x" > a.txt
    git add a.txt commitlint.config.js
  )
  out=$(bash "$COMMIT" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.convention')" = "conventional-commits" ]
  [ "$(echo "$out" | jq -r '.convention_source')" = "commitlint.config.js" ]
}

@test "detects pre-commit.com + commitizen → commitizen" {
  repo=$(make_repo)
  ( cd "$repo"
    cat > .pre-commit-config.yaml <<EOF
repos:
  - repo: https://github.com/commitizen-tools/commitizen
    rev: v3.0.0
    hooks:
      - id: commitizen
EOF
    echo "x" > a.txt
    git add a.txt .pre-commit-config.yaml
  )
  out=$(bash "$COMMIT" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.convention')" = "commitizen" ]
  [ "$(echo "$out" | jq -r '.convention_source')" = "pre-commit.com" ]
}

@test "falls back to default convention when no config present" {
  repo=$(make_repo)
  ( cd "$repo"
    echo "x" > a.txt
    git add a.txt
  )
  out=$(bash "$COMMIT" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.convention')" = "default" ]
  [ "$(echo "$out" | jq -r '.convention_source')" = "default" ]
}

# ---- diff truncation --------------------------------------------------------

@test "truncates oversized diffs and sets truncated=true" {
  repo=$(make_repo)
  ( cd "$repo"
    # Generate ~2KB of staged content; --max-diff-bytes 256 forces truncation.
    python3 -c "print('x' * 2000)" > big.txt
    git add big.txt
  )
  out=$(bash "$COMMIT" --target "$repo" --max-diff-bytes 256 2>/dev/null)
  [ "$(echo "$out" | jq -r '.truncated')" = "true" ]
  echo "$out" | jq -r '.diff' | grep -Fq "truncated"
}

@test "does not truncate small diffs" {
  repo=$(make_repo)
  ( cd "$repo"
    echo "tiny" > a.txt
    git add a.txt
  )
  out=$(bash "$COMMIT" --target "$repo" --max-diff-bytes 60000 2>/dev/null)
  [ "$(echo "$out" | jq -r '.truncated')" = "false" ]
}
