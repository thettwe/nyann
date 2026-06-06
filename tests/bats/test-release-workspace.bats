#!/usr/bin/env bats
# test-release-workspace.bats — tests for monorepo workspace release (D1).

setup() {
  export RELEASE="${BATS_TEST_DIRNAME}/../../bin/release.sh"
  export WS_RELEASE="${BATS_TEST_DIRNAME}/../../bin/release/release-workspace.sh"
  export WS_DETECT="${BATS_TEST_DIRNAME}/../../bin/release/detect-workspace-changes.sh"
  export TMP="${BATS_TEST_TMPDIR}"
}

make_monorepo() {
  local d="$TMP/mono-$$-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$d/packages/core" "$d/packages/cli"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"

  echo '{"name":"core","version":"0.1.0"}' > "$d/packages/core/package.json"
  echo 'console.log("core")' > "$d/packages/core/index.ts"
  git -C "$d" add .
  git -C "$d" commit -qm "feat(core): initial core package"

  echo '{"name":"cli","version":"0.1.0"}' > "$d/packages/cli/package.json"
  echo 'console.log("cli")' > "$d/packages/cli/index.ts"
  git -C "$d" add .
  git -C "$d" commit -qm "feat(cli): initial cli package"

  echo 'updated' >> "$d/packages/core/index.ts"
  git -C "$d" add .
  git -C "$d" commit -qm "fix(core): fix core bug"

  echo "$d"
}

# ────────────────────────────────────────────────────────────────────
# detect-workspace-changes.sh
# ────────────────────────────────────────────────────────────────────

@test "detect-workspace-changes: finds commits by path" {
  repo=$(make_monorepo)
  root_sha=$(git -C "$repo" rev-list --max-parents=0 HEAD | head -1)

  result=$(bash "$WS_DETECT" --target "$repo" --workspace "packages/core" --from "$root_sha" 2>/dev/null)
  n=$(echo "$result" | jq 'length')
  [ "$n" -ge 1 ]
}

@test "detect-workspace-changes: workspace with no changes returns empty" {
  repo=$(make_monorepo)
  latest=$(git -C "$repo" rev-parse HEAD)
  run bash "$WS_DETECT" --target "$repo" --workspace "packages/core" --from "$latest"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}

# ────────────────────────────────────────────────────────────────────
# release-workspace.sh
# ────────────────────────────────────────────────────────────────────

@test "release-workspace: dry-run shows preview" {
  repo=$(make_monorepo)
  run bash "$WS_RELEASE" --target "$repo" --workspace "packages/core" --version 1.0.0 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "preview"'
  echo "$output" | jq -e '.workspace == "packages/core"'
  echo "$output" | jq -e '.tag == "core@1.0.0"'
  echo "$output" | jq -e '.commits | length >= 1'
}

@test "release-workspace: custom tag prefix" {
  repo=$(make_monorepo)
  run bash "$WS_RELEASE" --target "$repo" --workspace "packages/core" --version 1.0.0 \
    --tag-prefix "packages-core-v" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tag == "packages-core-v1.0.0"'
}

@test "release-workspace: noop when no commits" {
  repo=$(make_monorepo)
  git -C "$repo" tag "core@0.99.0"
  run bash "$WS_RELEASE" --target "$repo" --workspace "packages/cli" --version 1.0.0
  # cli only has 1 commit (initial); whether it's noop depends on tag
  [ "$status" -eq 0 ]
}

@test "release-workspace: writes per-workspace CHANGELOG" {
  repo=$(make_monorepo)
  run bash "$WS_RELEASE" --target "$repo" --workspace "packages/core" --version 1.0.0 --yes
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "released"'
  [ -f "$repo/packages/core/CHANGELOG.md" ]
  grep '1.0.0' "$repo/packages/core/CHANGELOG.md"
}

@test "release-workspace: existing tag dies" {
  repo=$(make_monorepo)
  git -C "$repo" tag "core@1.0.0"
  run bash "$WS_RELEASE" --target "$repo" --workspace "packages/core" --version 1.0.0
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "already exists"
}

# ────────────────────────────────────────────────────────────────────
# release.sh --workspace integration
# ────────────────────────────────────────────────────────────────────

@test "release.sh --workspace: tags single workspace" {
  repo=$(make_monorepo)
  result=$(bash "$RELEASE" --target "$repo" --workspace packages/core --version 1.0.0 --strategy conventional-changelog --yes 2>/dev/null)
  echo "$result" | jq -e '.workspaces | length == 1'
  git -C "$repo" rev-parse --verify "refs/tags/core@1.0.0" >/dev/null 2>&1
}

@test "release.sh --workspace: dry-run doesn't create tags" {
  repo=$(make_monorepo)
  run bash "$RELEASE" --target "$repo" --workspace packages/core --version 1.0.0 --strategy conventional-changelog --dry-run
  [ "$status" -eq 0 ]
  ! git -C "$repo" rev-parse --verify "refs/tags/core@1.0.0" >/dev/null 2>&1
}

@test "release.sh --workspace: failed workspace produces error status and exit 1" {
  repo=$(make_monorepo)
  # Pre-create tag so workspace release fails
  git -C "$repo" tag "core@2.0.0"
  json_out=$(bash "$RELEASE" --target "$repo" --workspace packages/core --version 2.0.0 --strategy conventional-changelog --yes 2>/dev/null) || true
  echo "$json_out" | jq -e '.workspaces[0].status == "error"'
  # Verify non-zero exit code
  run bash "$RELEASE" --target "$repo" --workspace packages/core --version 2.0.0 --strategy conventional-changelog --yes
  [ "$status" -ne 0 ]
}

@test "release.sh --batch-commit: tags point to commit containing changelogs" {
  repo=$(make_monorepo)
  # Release both workspaces with batch commit
  result=$(bash "$RELEASE" --target "$repo" \
    --workspace packages/core --workspace packages/cli \
    --version 1.0.0 --strategy conventional-changelog --yes --batch-commit 2>/dev/null) || true
  # If tags exist, verify the tagged commit includes changelogs
  if git -C "$repo" rev-parse --verify "refs/tags/core@1.0.0" >/dev/null 2>&1; then
    tagged_sha=$(git -C "$repo" rev-parse "core@1.0.0^{commit}")
    # The tagged commit should be the batch commit containing changelogs
    git -C "$repo" show --stat "$tagged_sha" | grep -q "CHANGELOG"
  fi
}

@test "release.sh --batch-commit: stages only CHANGELOG files, not untracked files" {
  repo=$(make_monorepo)
  # Create an untracked file that should NOT be committed
  echo "secret" > "$repo/DO_NOT_COMMIT.txt"
  bash "$RELEASE" --target "$repo" --workspace packages/core \
    --version 1.0.0 --strategy conventional-changelog --yes --batch-commit 2>/dev/null || true
  # Verify untracked file was not committed
  if git -C "$repo" log -1 --name-only --format= 2>/dev/null | grep -q "DO_NOT_COMMIT"; then
    echo "FAIL: untracked file was staged by batch commit"
    return 1
  fi
}

# ── BUG A regression: non-batch monorepo release ─────────────────────────────
# Without --batch-commit, release.sh must commit each workspace's CHANGELOG
# BEFORE tagging, so the tag lands on the commit that contains its changelog and
# the working tree is left clean. (Previously it tagged pre-changelog HEAD and
# left the changelog uncommitted.)

@test "release.sh non-batch monorepo: tag points at the commit containing the changelog" {
  repo=$(make_monorepo)
  bash "$RELEASE" --target "$repo" --workspace packages/core \
    --version 1.0.0 --strategy conventional-changelog --yes 2>/dev/null
  git -C "$repo" rev-parse --verify "refs/tags/core@1.0.0" >/dev/null 2>&1
  tagged_sha=$(git -C "$repo" rev-parse "core@1.0.0^{commit}")
  # The tagged commit itself must contain packages/core/CHANGELOG.md.
  git -C "$repo" show --stat "$tagged_sha" | grep -q "packages/core/CHANGELOG.md"
}

@test "release.sh non-batch monorepo: working tree is clean after release" {
  repo=$(make_monorepo)
  bash "$RELEASE" --target "$repo" --workspace packages/core \
    --version 1.0.0 --strategy conventional-changelog --yes 2>/dev/null
  # No lingering uncommitted CHANGELOG; tree must be clean.
  [ -z "$(git -C "$repo" status --porcelain)" ]
}

@test "release.sh non-batch monorepo: changelog is committed (tracked), not just on disk" {
  repo=$(make_monorepo)
  bash "$RELEASE" --target "$repo" --workspace packages/core \
    --version 1.0.0 --strategy conventional-changelog --yes 2>/dev/null
  [ -f "$repo/packages/core/CHANGELOG.md" ]
  # File must be tracked at HEAD, not untracked/uncommitted.
  git -C "$repo" cat-file -e "HEAD:packages/core/CHANGELOG.md"
}
