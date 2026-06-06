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
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"
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
  # A real-looking author email is a valid CODEOWNERS owner; derive emits
  # it verbatim. (The default make_repo email "test@test" has no TLD and
  # is intentionally rejected — see the separate invalid-email test.)
  git -C "$repo" config user.email "alice@example.com"
  git -C "$repo" config user.name "Alice Wonderland"
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
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"
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

# ────────────────────────────────────────────────────────────────────
# derive-codeowners.sh — bug-fix regressions
# ────────────────────────────────────────────────────────────────────

@test "derive: all-bot directory does not abort; real dirs still emit JSON (BUG D)" {
  # A directory whose entire history is bot commits makes `grep -v` exit 1.
  # Under `set -euo pipefail` that previously aborted the whole script,
  # losing valid data from real-author dirs. The fix (`|| true`) must let
  # the all-bot dir be skipped while real dirs still appear in the output.
  repo=$(make_repo)
  # vendor/ — authored entirely by a bot.
  mkdir -p "$repo/vendor"
  git -C "$repo" config user.email "12345+dependabot[bot]@users.noreply.github.com"
  git -C "$repo" config user.name "dependabot[bot]"
  for i in $(seq 1 5); do
    echo "bot $i" >> "$repo/vendor/lib.js"
    git -C "$repo" add .
    git -C "$repo" commit -qm "chore: bump $i"
  done
  # src/ — authored by a real contributor with a valid email.
  git -C "$repo" config user.email "alice@example.com"
  git -C "$repo" config user.name "Alice Wonderland"
  for i in $(seq 1 5); do
    echo "real $i" >> "$repo/src/main.ts"
    git -C "$repo" add .
    git -C "$repo" commit -qm "feat: change $i"
  done
  run bash "$DERIVE" --target "$repo" --min-commits 3
  [ "$status" -eq 0 ]
  # Script did not abort: valid JSON array on stdout.
  echo "$output" | jq -e 'type == "array"'
  # src/ (real author) is present; vendor/ (all-bot) produced no owner.
  echo "$output" | jq -e 'any(.[]; .path == "/src/")'
  echo "$output" | jq -e 'all(.[]; .path != "/vendor/")'
}

@test "derive: noreply email yields an @handle, never a bare name (BUG E)" {
  repo=$(make_repo)
  git -C "$repo" config user.email "98765+alice-w@users.noreply.github.com"
  git -C "$repo" config user.name "Alice Wonderland"
  for i in $(seq 1 5); do
    echo "line $i" >> "$repo/src/main.ts"
    git -C "$repo" add .
    git -C "$repo" commit -qm "feat: change $i"
  done
  run bash "$DERIVE" --target "$repo" --min-commits 3
  [ "$status" -eq 0 ]
  # @handle is recovered from the noreply email; the bare display name
  # ("Alice Wonderland" / "AliceWonderland") is NOT used as the owner.
  echo "$output" | jq -e '.[] | select(.path == "/src/") | .suggested_owner == "@alice-w"'
  ! echo "$output" | jq -r '.[].suggested_owner' | grep -qi 'AliceWonderland'
}

@test "derive: unusable email leaves suggested_owner empty + keeps name (BUG E)" {
  repo=$(make_repo)
  # "test@test" has no TLD → not a valid CODEOWNERS owner.
  git -C "$repo" config user.email "test@test"
  git -C "$repo" config user.name "Local Dev"
  for i in $(seq 1 5); do
    echo "line $i" >> "$repo/src/main.ts"
    git -C "$repo" add .
    git -C "$repo" commit -qm "feat: change $i"
  done
  run bash "$DERIVE" --target "$repo" --min-commits 3
  [ "$status" -eq 0 ]
  # No bare-name owner: suggested_owner is empty, name preserved for a comment.
  echo "$output" | jq -e '.[] | select(.path == "/src/") | .suggested_owner == ""'
  echo "$output" | jq -e '.[] | select(.path == "/src/") | .suggested_name == "Local Dev"'
}

# ────────────────────────────────────────────────────────────────────
# gen-codeowners.sh — derived-owner rendering + malformed input guards
# ────────────────────────────────────────────────────────────────────

@test "gen: derived owner with no handle → comment, never an inert bare-name rule (BUG E)" {
  repo=$(make_repo)
  derived="$TMP/derived-$$.json"
  cat > "$derived" <<'JSON'
[
  {"path": "/src/", "suggested_owner": "", "suggested_name": "Local Dev", "commit_count": 7, "confidence": 0.9},
  {"path": "/api/", "suggested_owner": "@alice", "suggested_name": "Alice", "commit_count": 4, "confidence": 0.6}
]
JSON
  run bash "$GEN" --target "$repo" --derived-owners "$derived"
  [ "$status" -eq 0 ]
  co="$repo/.github/CODEOWNERS"
  [ -f "$co" ]
  # Valid handle → active rule.
  grep -Fq '/api/ @alice' "$co"
  # No-handle entry → a # suggested: comment, NOT a bare-name rule.
  grep -Fq '# suggested: /src/' "$co"
  ! grep -Eq '^/src/ [^@#]' "$co"
}

@test "gen: profile-owners entry missing owners does not crash (BUG F)" {
  repo=$(make_repo)
  owners_file="$TMP/owners-missing-$$.json"
  # First entry omits "owners" entirely (would raise jq "Cannot iterate
  # over null" and abort before the fix); second is well-formed.
  cat > "$owners_file" <<'JSON'
[
  {"pattern": "/legacy/"},
  {"pattern": "/src/", "owners": ["@alice"]}
]
JSON
  run bash "$GEN" --target "$repo" --profile-owners "$owners_file"
  [ "$status" -eq 0 ]
  co="$repo/.github/CODEOWNERS"
  [ -f "$co" ]
  # Malformed entry skipped; valid one written.
  grep -Fq '/src/ @alice' "$co"
  ! grep -Fq '/legacy/' "$co"
}

@test "gen: profile-owners entry missing pattern never writes a literal null rule (BUG F)" {
  repo=$(make_repo)
  owners_file="$TMP/owners-nullpat-$$.json"
  cat > "$owners_file" <<'JSON'
[
  {"owners": ["@ghost"]},
  {"pattern": "/src/", "owners": ["@alice"]}
]
JSON
  run bash "$GEN" --target "$repo" --profile-owners "$owners_file"
  [ "$status" -eq 0 ]
  co="$repo/.github/CODEOWNERS"
  [ -f "$co" ]
  grep -Fq '/src/ @alice' "$co"
  # The missing-pattern entry must NOT produce a `null @ghost` rule.
  ! grep -Fq 'null @ghost' "$co"
  ! grep -Eq '^null ' "$co"
}
