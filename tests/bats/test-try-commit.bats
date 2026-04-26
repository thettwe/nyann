#!/usr/bin/env bats
# bin/try-commit.sh — structured commit wrapper tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TRY_COMMIT="${REPO_ROOT}/bin/try-commit.sh"
  TMP=$(mktemp -d)

  # Set up a throwaway git repo for each test
  git init "$TMP/repo" >/dev/null 2>&1
  git -C "$TMP/repo" config user.email "test@test.com"
  git -C "$TMP/repo" config user.name "Test"
  echo "hello" > "$TMP/repo/file.txt"
  git -C "$TMP/repo" add file.txt
  git -C "$TMP/repo" commit -q -m "initial"
}

teardown() { rm -rf "$TMP"; }

@test "help flag prints usage" {
  run bash "$TRY_COMMIT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--subject"* ]]
}

@test "missing --subject dies" {
  run bash "$TRY_COMMIT" --target "$TMP/repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--subject is required"* ]]
}

@test "subject starting with dash is rejected" {
  run bash "$TRY_COMMIT" --target "$TMP/repo" --subject "-bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not start with"* ]]
}

@test "non-git directory dies" {
  run bash "$TRY_COMMIT" --target "$TMP" --subject "test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a git repo"* ]]
}

@test "successful commit returns committed result" {
  echo "change" >> "$TMP/repo/file.txt"
  git -C "$TMP/repo" add file.txt
  run bash "$TRY_COMMIT" --target "$TMP/repo" --subject "feat: test commit"
  [ "$status" -eq 0 ]
  result=$(echo "$output" | jq -r '.result')
  [ "$result" = "committed" ]
  sha=$(echo "$output" | jq -r '.sha')
  [ "$sha" != "null" ]
  [ ${#sha} -ge 7 ]
}

@test "commit with body passes both subject and body" {
  echo "change2" >> "$TMP/repo/file.txt"
  git -C "$TMP/repo" add file.txt
  run bash "$TRY_COMMIT" --target "$TMP/repo" --subject "feat: with body" --body "detailed description"
  [ "$status" -eq 0 ]
  result=$(echo "$output" | jq -r '.result')
  [ "$result" = "committed" ]
  msg=$(git -C "$TMP/repo" log -1 --format=%B)
  [[ "$msg" == *"detailed description"* ]]
}

@test "nothing to commit returns error result" {
  run bash "$TRY_COMMIT" --target "$TMP/repo" --subject "feat: empty"
  [ "$status" -eq 0 ]
  result=$(echo "$output" | jq -r '.result')
  [ "$result" = "error" ]
  exit_code=$(echo "$output" | jq -r '.exit_code')
  [ "$exit_code" -ne 0 ]
}

@test "output shape has all required fields" {
  echo "change3" >> "$TMP/repo/file.txt"
  git -C "$TMP/repo" add file.txt
  run bash "$TRY_COMMIT" --target "$TMP/repo" --subject "feat: shape test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("result", "sha", "subject", "stage", "reason", "exit_code")' >/dev/null
}

@test "rejected by commit-msg hook sets stage" {
  # Install a commit-msg hook that rejects everything
  mkdir -p "$TMP/repo/.git/hooks"
  printf '#!/usr/bin/env bash\necho "Conventional Commits violation" >&2\nexit 1\n' > "$TMP/repo/.git/hooks/commit-msg"
  chmod +x "$TMP/repo/.git/hooks/commit-msg"

  echo "change4" >> "$TMP/repo/file.txt"
  git -C "$TMP/repo" add file.txt
  run bash "$TRY_COMMIT" --target "$TMP/repo" --subject "bad commit"
  [ "$status" -eq 0 ]
  result=$(echo "$output" | jq -r '.result')
  [ "$result" = "rejected" ]
  stage=$(echo "$output" | jq -r '.stage')
  [ "$stage" = "commit-msg" ]
}
