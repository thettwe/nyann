#!/usr/bin/env bats
# bin/release.sh --bump-manifests — profile-driven version bumps in
# json/toml/script formats. Idempotency, validation, conflict with
# --strategy manual, dry-run preview.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RELEASE="${REPO_ROOT}/bin/release.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# Build a repo with a commit history + named profile file. The profile
# is written to $TMP/<name>.json and the path is echoed.
make_profile() {
  local name="$1" bump_files_json="$2"
  local prof="$TMP/${name}.json"
  jq -n --argjson bf "$bump_files_json" '{
    name: "test", schemaVersion: 2,
    stack: {primary_language:"unknown"},
    branching: {strategy:"github-flow", base_branches:["main"]},
    hooks: {pre_commit:[], commit_msg:[], pre_push:[]},
    extras: {gitignore:false, editorconfig:false, claude_md:false},
    conventions: {commit_format:"conventional-commits"},
    documentation: {},
    release: {bump_files: $bf}
  }' > "$prof"
  echo "$prof"
}

make_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: initial"
    git -c user.email=t@t -c user.name=t tag v0.1.0
    echo "a" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat: add a"
  )
  echo "$repo"
}

@test "json-version-key: bumps in dry-run preview without mutating" {
  repo=$(make_repo)
  echo '{"name":"x","version":"0.1.0"}' > "$repo/package.json"
  prof=$(make_profile "json-prof" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  out=$(bash "$RELEASE" --target "$repo" --version 1.2.3 --profile "$prof" --bump-manifests --dry-run)

  [ "$(echo "$out" | jq -r '.dry_run')" = "true" ]
  [ "$(echo "$out" | jq -r '.bumped_files | length')" = "1" ]
  [ "$(echo "$out" | jq -r '.bumped_files[0].path')" = "package.json" ]
  [ "$(echo "$out" | jq -r '.bumped_files[0].format')" = "json-version-key" ]
  [ "$(echo "$out" | jq -r '.bumped_files[0].action')" = "bumped" ]
  [ "$(echo "$out" | jq -r '.bumped_files[0].from_version')" = "0.1.0" ]
  # File untouched in dry-run.
  [ "$(jq -r '.version' "$repo/package.json")" = "0.1.0" ]
}

@test "json-version-key: real run mutates file and stages it in the release commit" {
  repo=$(make_repo)
  echo '{"name":"x","version":"0.1.0"}' > "$repo/package.json"
  prof=$(make_profile "json-prof" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  out=$(bash "$RELEASE" --target "$repo" --version 1.2.3 --profile "$prof" --bump-manifests --yes)
  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ "$(jq -r '.version' "$repo/package.json")" = "1.2.3" ]
  # Release commit includes both CHANGELOG.md and package.json.
  files=$(git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD)
  echo "$files" | grep -Fxq "CHANGELOG.md"
  echo "$files" | grep -Fxq "package.json"
}

@test "json-version-key: idempotent re-run reports unchanged" {
  repo=$(make_repo)
  echo '{"name":"x","version":"1.2.3"}' > "$repo/package.json"
  prof=$(make_profile "json-prof" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  out=$(bash "$RELEASE" --target "$repo" --version 1.2.3 --profile "$prof" --bump-manifests --dry-run)
  [ "$(echo "$out" | jq -r '.bumped_files[0].action')" = "unchanged" ]
  [ "$(echo "$out" | jq -r '.bumped_files[0].from_version')" = "1.2.3" ]
}

@test "json-version-key: nested key (.plugins[0].version) works" {
  repo=$(make_repo)
  echo '{"plugins":[{"version":"0.1.0"}]}' > "$repo/marketplace.json"
  prof=$(make_profile "nest-prof" '[{"path":"marketplace.json","format":"json-version-key","key":".plugins[0].version"}]')

  bash "$RELEASE" --target "$repo" --version 2.0.0 --profile "$prof" --bump-manifests --yes >/dev/null
  [ "$(jq -r '.plugins[0].version' "$repo/marketplace.json")" = "2.0.0" ]
}

@test "toml-version-key: bumps version inside named section" {
  repo=$(make_repo)
  cat > "$repo/pyproject.toml" <<'TOML'
[project]
name = "x"
version = "0.1.0"
description = "test"

[tool.other]
version = "9.9.9"
TOML
  prof=$(make_profile "toml-prof" '[{"path":"pyproject.toml","format":"toml-version-key","section":"project"}]')

  bash "$RELEASE" --target "$repo" --version 1.5.0 --profile "$prof" --bump-manifests --yes >/dev/null

  # Project section bumped, [tool.other] left alone.
  grep -E '^\[project\]' "$repo/pyproject.toml"
  grep -E '^version = "1.5.0"$' "$repo/pyproject.toml"
  # The 9.9.9 in [tool.other] must NOT be touched.
  grep -E '^version = "9.9.9"$' "$repo/pyproject.toml"
}

@test "toml-version-key: missing version in section dies loudly" {
  repo=$(make_repo)
  cat > "$repo/pyproject.toml" <<'TOML'
[project]
name = "x"
TOML
  prof=$(make_profile "missing-toml" '[{"path":"pyproject.toml","format":"toml-version-key","section":"project"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "could not find single-line"
}

@test "script format: invokes command with NEW_VERSION env" {
  repo=$(make_repo)
  echo "0.1.0" > "$repo/VERSION"
  prof=$(make_profile "script-prof" '[{"path":"VERSION","format":"script","command":"echo \"$NEW_VERSION\" > VERSION"}]')

  bash "$RELEASE" --target "$repo" --version 3.0.0 --profile "$prof" --bump-manifests --yes >/dev/null
  [ "$(cat "$repo/VERSION")" = "3.0.0" ]
}

@test "script format: failing command dies with the file path" {
  repo=$(make_repo)
  echo "0.1.0" > "$repo/VERSION"
  prof=$(make_profile "fail-script" '[{"path":"VERSION","format":"script","command":"false"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "VERSION"
}

@test "missing file dies with the path in the error" {
  repo=$(make_repo)
  prof=$(make_profile "missing-file" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "package.json"
}

@test "path with .. in profile is rejected up-front" {
  repo=$(make_repo)
  prof=$(make_profile "bad-path" '[{"path":"../etc/passwd","format":"json-version-key","key":".version"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e ".."
}

@test "--bump-manifests + --strategy manual dies up-front" {
  repo=$(make_repo)
  echo '{"version":"0.1.0"}' > "$repo/package.json"
  prof=$(make_profile "manual-conflict" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --strategy manual
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "manual strategy creates no commit"
}

@test "no bump_files in profile is a no-op (logs and proceeds)" {
  repo=$(make_repo)
  prof=$(make_profile "empty" '[]')

  out=$(bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --dry-run)
  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ "$(echo "$out" | jq -r '.bumped_files | length')" = "0" ]
}

@test "multiple files bump in one release commit" {
  repo=$(make_repo)
  echo '{"version":"0.1.0"}' > "$repo/a.json"
  echo '{"version":"0.1.0"}' > "$repo/b.json"
  prof=$(make_profile "multi" '[
    {"path":"a.json","format":"json-version-key","key":".version"},
    {"path":"b.json","format":"json-version-key","key":".version"}
  ]')

  bash "$RELEASE" --target "$repo" --version 2.0.0 --profile "$prof" --bump-manifests --yes >/dev/null
  [ "$(jq -r '.version' "$repo/a.json")" = "2.0.0" ]
  [ "$(jq -r '.version' "$repo/b.json")" = "2.0.0" ]
  files=$(git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD)
  echo "$files" | grep -Fxq "a.json"
  echo "$files" | grep -Fxq "b.json"
}

@test "without --bump-manifests, profile.bump_files is ignored" {
  repo=$(make_repo)
  echo '{"version":"0.1.0"}' > "$repo/package.json"
  prof=$(make_profile "ignored" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  out=$(bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --dry-run)
  # Without --bump-manifests, bumped_files should NOT be in the output.
  [ "$(echo "$out" | jq -r 'has("bumped_files")')" = "false" ]
  # File stays untouched in dry-run.
  [ "$(jq -r '.version' "$repo/package.json")" = "0.1.0" ]
}

@test "prerelease version + --bump-manifests dies up-front" {
  repo=$(make_repo)
  echo '{"version":"0.1.0"}' > "$repo/package.json"
  prof=$(make_profile "rc" '[{"path":"package.json","format":"json-version-key","key":".version"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0-rc.1 --profile "$prof" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "prerelease"
  # File untouched — the prerelease guard must catch it BEFORE
  # compute_bump_plan would have populated bumped_files_json. This is
  # the bug-hunt P0: dry-run lying about real-run.
  [ "$(jq -r '.version' "$repo/package.json")" = "0.1.0" ]
}

@test "mixed bumped+unchanged in one run lands only the changed file in the commit" {
  repo=$(make_repo)
  echo '{"version":"0.1.0"}' > "$repo/a.json"
  echo '{"version":"2.0.0"}' > "$repo/b.json"   # already at target
  prof=$(make_profile "mixed" '[
    {"path":"a.json","format":"json-version-key","key":".version"},
    {"path":"b.json","format":"json-version-key","key":".version"}
  ]')

  out=$(bash "$RELEASE" --target "$repo" --version 2.0.0 --profile "$prof" --bump-manifests --yes)
  [ "$(echo "$out" | jq -r '.bumped_files | length')" = "2" ]
  # a.json was at 0.1.0 → bumped. b.json was already 2.0.0 → unchanged.
  [ "$(echo "$out" | jq -r '.bumped_files[] | select(.path=="a.json") | .action')" = "bumped" ]
  [ "$(echo "$out" | jq -r '.bumped_files[] | select(.path=="b.json") | .action')" = "unchanged" ]
  # Only a.json should be in the release commit's tree changes.
  files=$(git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD)
  echo "$files" | grep -Fxq "a.json"
  ! echo "$files" | grep -Fxq "b.json"
}

@test "missing --profile file dies with the path in the error" {
  repo=$(make_repo)
  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "/tmp/nope-$$.json" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "/tmp/nope-$$.json"
}

@test "json-version-key with shell-injection .key is rejected at runtime" {
  repo=$(make_repo)
  echo '{"version":"0.1.0"}' > "$repo/package.json"
  # `key` is structurally illegal — bypasses the schema regex by hand-
  # editing the profile file. Defence-in-depth runtime check should
  # still refuse.
  prof=$(make_profile "evil-key" '[{"path":"package.json","format":"json-version-key","key":". | env"}]')

  run bash "$RELEASE" --target "$repo" --version 1.0.0 --profile "$prof" --bump-manifests --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "simple jq path"
  # File stays untouched — the rejection happened before mutation.
  [ "$(jq -r '.version' "$repo/package.json")" = "0.1.0" ]
}
