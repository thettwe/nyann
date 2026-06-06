#!/usr/bin/env bats
# Structural validation of the plugin + marketplace manifests via
# tests/validate-manifest.sh (the same check CI runs).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VALIDATOR="$REPO_ROOT/tests/validate-manifest.sh"
  # Work on a copy so failure-path tests can corrupt the manifests freely.
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/.claude-plugin" "$WORK/tests"
  cp "$REPO_ROOT/.claude-plugin/plugin.json" "$WORK/.claude-plugin/"
  cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$WORK/.claude-plugin/"
  cp "$VALIDATOR" "$WORK/tests/validate-manifest.sh"
}

@test "the real repo manifests validate" {
  run bash "$VALIDATOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "invalid JSON in plugin.json fails" {
  echo '{ not json' > "$WORK/.claude-plugin/plugin.json"
  run bash "$WORK/tests/validate-manifest.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "missing required field fails" {
  jq 'del(.version)' "$WORK/.claude-plugin/plugin.json" > "$WORK/.claude-plugin/plugin.json.tmp"
  mv "$WORK/.claude-plugin/plugin.json.tmp" "$WORK/.claude-plugin/plugin.json"
  run bash "$WORK/tests/validate-manifest.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: version"* ]]
}

@test "version drift between plugin.json and marketplace entry fails" {
  jq '.version = "9.9.9"' "$WORK/.claude-plugin/plugin.json" > "$WORK/.claude-plugin/plugin.json.tmp"
  mv "$WORK/.claude-plugin/plugin.json.tmp" "$WORK/.claude-plugin/plugin.json"
  run bash "$WORK/tests/validate-manifest.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version drift"* ]]
}

@test "non-semver version fails" {
  jq '.version = "v1"' "$WORK/.claude-plugin/plugin.json" > "$WORK/.claude-plugin/plugin.json.tmp"
  mv "$WORK/.claude-plugin/plugin.json.tmp" "$WORK/.claude-plugin/plugin.json"
  run bash "$WORK/tests/validate-manifest.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not semver"* ]]
}

@test "marketplace source that does not resolve fails" {
  jq '(.plugins[] | select(.name=="nyann")).source = "./does-not-exist/"' \
    "$WORK/.claude-plugin/marketplace.json" > "$WORK/.claude-plugin/marketplace.json.tmp"
  mv "$WORK/.claude-plugin/marketplace.json.tmp" "$WORK/.claude-plugin/marketplace.json"
  run bash "$WORK/tests/validate-manifest.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not resolve"* ]]
}
