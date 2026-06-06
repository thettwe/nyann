#!/usr/bin/env bats
# bin/new-branch.sh — slug/version validation + branch creation.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NEW_BRANCH="${REPO_ROOT}/bin/new-branch.sh"
  TMP=$(mktemp -d)
  UR="$TMP/user-root"
  REPO="$TMP/repo"

  # Minimal git repo with a main branch, seeded.
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "init" )
}

teardown() { rm -rf "$TMP"; }

@test "rejects invalid slug (uppercase)" {
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose feature --slug "BadSlug"
  [ "$status" -eq 4 ]
  echo "$output" | grep -F "invalid slug"
}

@test "rejects invalid version (not semver)" {
  # Regression: $version had no validation — arbitrary values would get
  # substituted into the branch-name pattern. release.sh validated semver;
  # new-branch.sh didn't. This test ensures the two stay in sync.
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose release --version "1.0.0 && rm -rf /"
  [ "$status" -eq 4 ]
  echo "$output" | grep -F "invalid version"
}

@test "rejects invalid version (whitespace)" {
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose release --version "1.0.0 "
  [ "$status" -eq 4 ]
  echo "$output" | grep -F "invalid version"
}

@test "rejects invalid version (path traversal attempt)" {
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose release --version "../../etc"
  [ "$status" -eq 4 ]
  echo "$output" | grep -F "invalid version"
}

@test "accepts valid semver version" {
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose release --version "1.2.3"
  # Depends on default profile having a release pattern. If it doesn't
  # (exit 3 = invalid purpose for strategy), that's still "past the
  # validation gate" — which is the thing under test here.
  [ "$status" -ne 4 ]
}

@test "accepts semver with prerelease" {
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose release --version "1.0.0-rc.1"
  [ "$status" -ne 4 ]
}

@test "rejects slug that assembles into an invalid git ref (double-dot)" {
  # Regression: `a..b` passes the slug regex (^[a-z0-9][a-z0-9._-]*$) but
  # `..` is forbidden in git refs. Previously the assembled name flowed
  # straight into `git branch`, surfacing a raw `fatal: not a valid
  # branch name` (exit 128). It must now be caught with a nyann-formatted
  # error and no branch created.
  run bash "$NEW_BRANCH" --target "$REPO" --profile default \
    --purpose feature --slug "a..b"
  [ "$status" -eq 4 ]
  echo "$output" | grep -F "not a valid git ref"
  # No git fatal leaked to the user.
  ! echo "$output" | grep -qF "fatal:"
  # Fail-safe: no branch matching the bad name was created.
  [ -z "$(git -C "$REPO" branch --list '*a..b*')" ]
}
