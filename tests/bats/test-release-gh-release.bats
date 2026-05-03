#!/usr/bin/env bats
# bin/release.sh --gh-release — GitHub release creation after the tag
# push. Soft-skip when gh missing/unauthed; --prerelease flag for SemVer
# pre-releases; refuse without --push.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RELEASE="${REPO_ROOT}/bin/release.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# Build a repo with a CC commit history + a working file:// remote so
# `--push` succeeds deterministically. The remote is a bare repo at
# $TMP/remote.git.
make_pushable_repo() {
  local repo="$TMP/repo" remote="$TMP/remote.git"
  git init -q --bare "$remote"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: initial"
    git -c user.email=t@t -c user.name=t tag v0.1.0
    echo "a" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat(api): add endpoint"
    git remote add origin "file://$remote"
    # Push the initial main so the branch exists upstream — release.sh's
    # branch push otherwise fails for a brand-new branch.
    git push -q origin main >/dev/null 2>&1 || true
    git push -q origin v0.1.0 >/dev/null 2>&1 || true
  )
  echo "$repo"
}

# Mock gh that handles auth + release create. The mock writes every
# invocation to $TMP/gh-calls.log so tests can assert what flags were
# passed.
make_mock_gh_release_create() {
  local outcome="${1:-success}"  # success | fail
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
# Log every call for assertions.
printf '%s\n' "\$*" >> "$TMP/gh-calls.log"

case "\$1" in
  auth) exit 0 ;;
  release)
    if [ "\$2" = "create" ]; then
      case "${outcome}" in
        success)
          # gh prints the release URL on success.
          tag="\$3"
          echo "https://github.com/example/repo/releases/tag/\$tag"
          exit 0
          ;;
        fail)
          echo "release create failed: simulated error" 1>&2
          exit 1
          ;;
      esac
    fi
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  : > "$TMP/gh-calls.log"
}

@test "--gh-release without --push dies up-front" {
  repo=$(make_pushable_repo)
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --gh-release --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--gh-release requires --push"
}

@test "--gh-release: happy path → outcome:created with URL" {
  repo=$(make_pushable_repo)
  make_mock_gh_release_create success

  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push --gh-release \
    --gh "$TMP/mock/gh" 2>/dev/null)

  [ "$(echo "$out" | jq -r '.gh_release.outcome')" = "created" ]
  [ "$(echo "$out" | jq -r '.gh_release.url')" = "https://github.com/example/repo/releases/tag/v0.2.0" ]
  [ "$(echo "$out" | jq -r '.gh_release.prerelease')" = "false" ]
  # Confirm gh was called with --notes-file (not --notes inline).
  grep -F -e "release create v0.2.0 --title v0.2.0 --notes-file" "$TMP/gh-calls.log"
  # No --prerelease for a stable version.
  ! grep -F -e "--prerelease" "$TMP/gh-calls.log"
}

@test "--gh-release prerelease version → --prerelease passed to gh + flagged in JSON" {
  repo=$(make_pushable_repo)
  make_mock_gh_release_create success

  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0-rc.1 --yes --push --gh-release \
    --gh "$TMP/mock/gh" 2>/dev/null)

  [ "$(echo "$out" | jq -r '.gh_release.outcome')" = "created" ]
  [ "$(echo "$out" | jq -r '.gh_release.prerelease')" = "true" ]
  grep -F -e "--prerelease" "$TMP/gh-calls.log"
}

@test "--gh-release: gh missing → outcome:skipped + next_steps recovery cmd" {
  repo=$(make_pushable_repo)

  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push --gh-release \
    --gh "/tmp/definitely-not-gh-$$" 2>/dev/null) && rc=0 || rc=$?

  # Tag still got pushed; --gh-release was a soft-skip, so exit code
  # comes from the push step (which succeeded → 0).
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.gh_release.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.gh_release.skipped_reason')" = "gh-not-installed" ]
  echo "$out" | jq -r '.next_steps[]' | grep -F -e "gh release create"
}

@test "--gh-release: gh unauthed → outcome:skipped + next_steps with auth login" {
  repo=$(make_pushable_repo)
  # Mock that fails auth status.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 1 ;;
  *)    exit 0 ;;
esac
SH
  chmod +x "$TMP/mock/gh"

  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push --gh-release \
    --gh "$TMP/mock/gh" 2>/dev/null)

  [ "$(echo "$out" | jq -r '.gh_release.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.gh_release.skipped_reason')" = "gh-not-authenticated" ]
  echo "$out" | jq -r '.next_steps[]' | grep -F -e "gh auth login"
}

@test "--gh-release: gh release create fails → outcome:failed + next_steps recovery" {
  repo=$(make_pushable_repo)
  make_mock_gh_release_create fail

  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push --gh-release \
    --gh "$TMP/mock/gh" 2>/dev/null)

  [ "$(echo "$out" | jq -r '.gh_release.outcome')" = "failed" ]
  echo "$out" | jq -r '.gh_release.error' | grep -F -e "simulated error"
  echo "$out" | jq -r '.next_steps[]' | grep -F -e "gh release create"
  # Tag stays on origin even when the GH release call failed — we never
  # undo a pushed tag.
  git -C "$repo" ls-remote --tags origin | grep -F -e "v0.2.0"
}

@test "without --gh-release, gh_release field is absent from output" {
  repo=$(make_pushable_repo)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push 2>/dev/null)
  [ "$(echo "$out" | jq -r 'has("gh_release")')" = "false" ]
}

@test "--gh-release dry-run skips the gh call entirely" {
  repo=$(make_pushable_repo)
  make_mock_gh_release_create success

  bash "$RELEASE" --target "$repo" --version 0.2.0 --dry-run --push --gh-release \
    --gh "$TMP/mock/gh" >/dev/null 2>&1 || true

  # gh-calls.log should be empty (or non-existent) — dry-run never
  # invoked the mock.
  [ ! -s "$TMP/gh-calls.log" ] || [ ! -e "$TMP/gh-calls.log" ]
}
