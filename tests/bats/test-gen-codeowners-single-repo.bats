#!/usr/bin/env bats
# test-gen-codeowners-single-repo.bats — tests for single-repo CODEOWNERS + git-history derivation.

setup() {
  export GEN="${BATS_TEST_DIRNAME}/../../bin/gen-codeowners.sh"
  export DERIVE="${BATS_TEST_DIRNAME}/../../bin/derive-codeowners.sh"
  export TMP="${BATS_TEST_TMPDIR}"
}

make_repo() {
  local d="$TMP/repo-$$-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$d/src" "$d/tests" "$d/.github"
  git -C "$d" init -q
  echo "code" > "$d/src/main.ts"
  echo "test" > "$d/tests/main.test.ts"
  git -C "$d" add .
  git -C "$d" commit -qm "feat: initial"
  echo "$d"
}

# ────────────────────────────────────────────────────────────────────
# profile-owners support
# ────────────────────────────────────────────────────────────────────

@test "profile-owners: generates CODEOWNERS from explicit mappings" {
  repo=$(make_repo)
  owners_file="$TMP/owners-$$.json"
  cat > "$owners_file" <<'JSON'
[
  {"pattern": "/src/", "owners": ["@alice"]},
  {"pattern": "*.proto", "owners": ["@bob", "@org/infra"]}
]
JSON
  run bash "$GEN" --target "$repo" --profile-owners "$owners_file"
  [ "$status" -eq 0 ]
  [ -f "$repo/.github/CODEOWNERS" ]
  grep '/src/ @alice' "$repo/.github/CODEOWNERS"
  grep '\*.proto @bob @org/infra' "$repo/.github/CODEOWNERS"
}

@test "profile-owners: marker idempotency on regeneration" {
  repo=$(make_repo)
  owners_file="$TMP/owners-idem-$$.json"
  cat > "$owners_file" <<'JSON'
[{"pattern": "/api/", "owners": ["@dev"]}]
JSON
  bash "$GEN" --target "$repo" --profile-owners "$owners_file" >/dev/null 2>&1
  bash "$GEN" --target "$repo" --profile-owners "$owners_file" >/dev/null 2>&1
  count=$(grep -c 'nyann:codeowners:start' "$repo/.github/CODEOWNERS")
  [ "$count" -eq 1 ]
}

@test "profile-owners: preserves content outside markers" {
  repo=$(make_repo)
  mkdir -p "$repo/.github"
  echo "# Manual entry" > "$repo/.github/CODEOWNERS"
  echo "*.md @docs-team" >> "$repo/.github/CODEOWNERS"

  owners_file="$TMP/owners-preserve-$$.json"
  cat > "$owners_file" <<'JSON'
[{"pattern": "/src/", "owners": ["@alice"]}]
JSON
  bash "$GEN" --target "$repo" --profile-owners "$owners_file" >/dev/null 2>&1
  grep '# Manual entry' "$repo/.github/CODEOWNERS"
  grep '\*.md @docs-team' "$repo/.github/CODEOWNERS"
  grep '/src/ @alice' "$repo/.github/CODEOWNERS"
}

@test "no ownership sources → skips silently" {
  repo=$(make_repo)
  run bash "$GEN" --target "$repo"
  [ "$status" -eq 0 ]
  [ ! -f "$repo/.github/CODEOWNERS" ]
}

@test "dry-run emits content without writing" {
  repo=$(make_repo)
  owners_file="$TMP/owners-dry-$$.json"
  cat > "$owners_file" <<'JSON'
[{"pattern": "/src/", "owners": ["@alice"]}]
JSON
  run bash "$GEN" --target "$repo" --profile-owners "$owners_file" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep '/src/ @alice'
  [ ! -f "$repo/.github/CODEOWNERS" ]
}

# ────────────────────────────────────────────────────────────────────
# derive-codeowners.sh
# ────────────────────────────────────────────────────────────────────

@test "derive: suggests owners from git history" {
  repo=$(make_repo)
  # Add more commits to meet min threshold
  for i in $(seq 2 6); do
    echo "line $i" >> "$repo/src/main.ts"
    git -C "$repo" add .
    git -C "$repo" commit -qm "feat: change $i"
  done
  run bash "$DERIVE" --target "$repo" --min-commits 3
  [ "$status" -eq 0 ]
  n=$(echo "$output" | jq 'length')
  [ "$n" -ge 1 ]
  echo "$output" | jq -e '.[0].suggested_owner | length > 0'
  echo "$output" | jq -e '.[0].commit_count >= 3'
}

@test "derive: empty repo returns empty array" {
  d="$TMP/empty-$$"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" commit --allow-empty -qm "init"
  run bash "$DERIVE" --target "$d"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}

@test "derive: not a git repo → error" {
  d="$TMP/notgit-$$"
  mkdir -p "$d"
  run bash "$DERIVE" --target "$d"
  [ "$status" -ne 0 ]
}

@test "derive: respects --min-commits threshold" {
  repo=$(make_repo)
  # Only 1 commit, min is 5
  run bash "$DERIVE" --target "$repo" --min-commits 5
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}
