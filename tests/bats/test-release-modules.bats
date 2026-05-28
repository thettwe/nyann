#!/usr/bin/env bats
# test-release-modules.bats — unit tests for the extracted bin/release/ modules.
# These test each module in isolation; test-release.bats is the regression suite.

setup() {
  export COLLECT="${BATS_TEST_DIRNAME}/../../bin/release/collect-commits.sh"
  export RENDER="${BATS_TEST_DIRNAME}/../../bin/release/render-changelog.sh"
  export BUMP="${BATS_TEST_DIRNAME}/../../bin/release/bump-manifests.sh"
  export CI_GATE="${BATS_TEST_DIRNAME}/../../bin/release/ci-gate.sh"
  export PUSH="${BATS_TEST_DIRNAME}/../../bin/release/push-release.sh"
  export GH_REL="${BATS_TEST_DIRNAME}/../../bin/release/github-release.sh"
  export TMP="${BATS_TEST_TMPDIR}"
}

make_repo() {
  local d="$TMP/repo-$$-$RANDOM"
  mkdir -p "$d" && cd "$d"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  git commit --allow-empty -qm "feat: initial feature"
  git commit --allow-empty -qm "fix(core): a bug fix"
  git commit --allow-empty -qm "chore: something"
  echo "$d"
}

# ────────────────────────────────────────────────────────────────────
# collect-commits.sh
# ────────────────────────────────────────────────────────────────────

@test "collect-commits: parses CC types from log range" {
  repo=$(make_repo)
  run bash "$COLLECT" --target "$repo" --log-range HEAD
  [ "$status" -eq 0 ]
  n=$(echo "$output" | jq 'length')
  [ "$n" -eq 3 ]
  # git log returns newest first
  echo "$output" | jq -e '.[0].type == "chore"'
  echo "$output" | jq -e '.[1].type == "fix"'
  echo "$output" | jq -e '.[1].scope == "core"'
  echo "$output" | jq -e '.[2].type == "feat"'
}

@test "collect-commits: empty range returns empty array" {
  repo=$(make_repo)
  tag=$(git -C "$repo" rev-parse HEAD)
  run bash "$COLLECT" --target "$repo" --log-range "${tag}..HEAD"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}

@test "collect-commits: detects breaking change" {
  repo="$TMP/repo-break-$$"
  mkdir -p "$repo" && cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  git commit --allow-empty -qm "feat!: breaking thing"
  run bash "$COLLECT" --target "$repo" --log-range HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].breaking == true'
}

@test "collect-commits: sanitises tabs and newlines in subject" {
  repo="$TMP/repo-tab-$$"
  mkdir -p "$repo" && cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  printf 'feat: with\ttab' | git commit --allow-empty -qm "$(cat)"
  run bash "$COLLECT" --target "$repo" --log-range HEAD
  [ "$status" -eq 0 ]
  # tab should be replaced with space
  echo "$output" | jq -e '.[0].subject | test("\t") | not'
}

# ────────────────────────────────────────────────────────────────────
# render-changelog.sh
# ────────────────────────────────────────────────────────────────────

@test "render-changelog: produces markdown with version header" {
  commits='[{"sha":"abc1234567","type":"feat","scope":"","subject":"new thing","breaking":false}]'
  run bash -c "echo '$commits' | bash '$RENDER' --version 1.2.3"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "## [1.2.3]"
  echo "$output" | grep -F "### Features"
  echo "$output" | grep -F "new thing (abc1234)"
}

@test "render-changelog: groups sections correctly" {
  commits='[
    {"sha":"aaa1234567","type":"feat","scope":"","subject":"a feature","breaking":false},
    {"sha":"bbb1234567","type":"fix","scope":"ui","subject":"a fix","breaking":false},
    {"sha":"ccc1234567","type":"chore","scope":"","subject":"a chore","breaking":false}
  ]'
  run bash -c "echo '$commits' | bash '$RENDER' --version 2.0.0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "### Features"
  echo "$output" | grep -F "### Fixes"
  echo "$output" | grep -F "### Chores"
  echo "$output" | grep -F "**ui**: a fix"
}

@test "render-changelog: breaking changes section appears first" {
  commits='[
    {"sha":"aaa1234567","type":"feat","scope":"","subject":"normal feat","breaking":false},
    {"sha":"bbb1234567","type":"feat","scope":"api","subject":"breaking feat","breaking":true}
  ]'
  run bash -c "echo '$commits' | bash '$RENDER' --version 3.0.0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "Breaking changes"
  # Breaking section must appear before Features
  breaking_line=$(echo "$output" | grep -n "Breaking" | head -1 | cut -d: -f1)
  features_line=$(echo "$output" | grep -n "Features" | head -1 | cut -d: -f1)
  [ "$breaking_line" -lt "$features_line" ]
}

@test "render-changelog: reads from --commits-file" {
  f="$TMP/commits-$$.json"
  echo '[{"sha":"abc1234567","type":"fix","scope":"","subject":"a fix","breaking":false}]' > "$f"
  run bash "$RENDER" --version 1.0.0 --commits-file "$f"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F "### Fixes"
}

@test "render-changelog: --version required" {
  run bash "$RENDER" <<< '[]'
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "version"
}

# ────────────────────────────────────────────────────────────────────
# bump-manifests.sh (compute mode)
# ────────────────────────────────────────────────────────────────────

@test "bump-manifests compute: emits plan for json-version-key" {
  repo="$TMP/repo-bump-$$"
  mkdir -p "$repo" && cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  echo '{"version":"0.1.0"}' > package.json
  git add . && git commit -qm "init"
  prof="$TMP/prof-$$.json"
  cat > "$prof" <<'JSON'
{"name":"test","schemaVersion":1,"release":{"bump_files":[{"path":"package.json","format":"json-version-key","key":".version"}]}}
JSON
  run bash "$BUMP" --mode compute --target "$repo" --version 1.0.0 --profile "$prof"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.bumped_files | length == 1'
  echo "$output" | jq -e '.bumped_files[0].action == "bumped"'
  echo "$output" | jq -e '.bumped_files[0].from_version == "0.1.0"'
  echo "$output" | jq -e '.plan | length == 1'
  echo "$output" | jq -e '.plan[0].digest | length > 0'
}

@test "bump-manifests compute: unchanged when already at target version" {
  repo="$TMP/repo-unch-$$"
  mkdir -p "$repo" && cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  echo '{"version":"1.0.0"}' > package.json
  git add . && git commit -qm "init"
  prof="$TMP/prof-unch-$$.json"
  cat > "$prof" <<'JSON'
{"name":"test","schemaVersion":1,"release":{"bump_files":[{"path":"package.json","format":"json-version-key","key":".version"}]}}
JSON
  run bash "$BUMP" --mode compute --target "$repo" --version 1.0.0 --profile "$prof"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.bumped_files[0].action == "unchanged"'
  echo "$output" | jq -e '.plan | length == 0'
}

# ────────────────────────────────────────────────────────────────────
# bump-manifests.sh (apply mode)
# ────────────────────────────────────────────────────────────────────

@test "bump-manifests apply: writes version to file" {
  repo="$TMP/repo-apply-$$"
  mkdir -p "$repo" && cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  echo '{"version":"0.1.0"}' > package.json
  git add . && git commit -qm "init"

  digest=$(shasum -a 256 package.json | awk '{print $1}')
  plan="$TMP/plan-$$.json"
  cat > "$plan" <<JSON
{"bumped_files":[],"plan":[{"path":"package.json","format":"json-version-key","payload":".version","digest":"$digest"}]}
JSON

  run bash "$BUMP" --mode apply --target "$repo" --version 2.0.0 --plan-file "$plan"
  [ "$status" -eq 0 ]
  new_ver=$(jq -r '.version' "$repo/package.json")
  [ "$new_ver" = "2.0.0" ]
}

@test "bump-manifests apply: TOCTOU digest mismatch dies" {
  repo="$TMP/repo-toctou-$$"
  mkdir -p "$repo" && cd "$repo"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  echo '{"version":"0.1.0"}' > package.json
  git add . && git commit -qm "init"

  plan="$TMP/plan-toctou-$$.json"
  cat > "$plan" <<'JSON'
{"bumped_files":[],"plan":[{"path":"package.json","format":"json-version-key","payload":".version","digest":"badhash"}]}
JSON

  run bash "$BUMP" --mode apply --target "$repo" --version 2.0.0 --plan-file "$plan"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "digest mismatch"
}

# ────────────────────────────────────────────────────────────────────
# github-release.sh
# ────────────────────────────────────────────────────────────────────

@test "github-release: soft-skips when gh not installed" {
  run bash "$GH_REL" --tag v1.0.0 --gh /nonexistent/gh
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "skipped"'
  echo "$output" | jq -e '.skipped_reason == "gh-not-installed"'
}

@test "github-release: soft-skips when tag not pushed" {
  run bash -c "bash '$GH_REL' --tag v1.0.0 --tag-not-pushed 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "skipped"'
  echo "$output" | jq -e '.skipped_reason == "tag-not-pushed"'
}

@test "github-release: --tag required" {
  run bash "$GH_REL"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "tag"
}
