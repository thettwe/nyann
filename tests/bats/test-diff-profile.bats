#!/usr/bin/env bats
# bin/diff-profile.sh — profile diff tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DIFF="${REPO_ROOT}/bin/diff-profile.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# --- basic functionality ---

@test "produces valid JSON output" {
  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e . "$TMP/out.json" >/dev/null
}

@test "from and to fields match arguments" {
  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  [ "$(jq -r '.from' "$TMP/out.json")" = "default" ]
  [ "$(jq -r '.to' "$TMP/out.json")" = "python-cli" ]
}

@test "identical profiles show identical=true" {
  bash "$DIFF" default default --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  [ "$(jq -r '.identical' "$TMP/out.json")" = "true" ]
  [ "$(jq '.total_changes' "$TMP/out.json")" -eq 0 ]
}

# --- detecting changes ---

@test "different languages show stack changes" {
  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  [ "$(jq -r '.identical' "$TMP/out.json")" = "false" ]
  jq -e '.sections.stack | length > 0' "$TMP/out.json" >/dev/null
  jq -e '.sections.stack | map(select(.field == "primary_language")) | length > 0' "$TMP/out.json" >/dev/null
}

@test "hook differences are captured" {
  bash "$DIFF" default nextjs-prototype --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  hooks_count=$(jq '.sections.hooks | length' "$TMP/out.json")
  [ "$hooks_count" -ge 1 ]
}

@test "total_changes counts all section changes" {
  bash "$DIFF" default nextjs-prototype --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  total=$(jq '.total_changes' "$TMP/out.json")
  [ "$total" -gt 0 ]
}

# --- all sections present ---

@test "all ten sections present in output" {
  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  for section in stack branching hooks conventions documentation extras ci governance github release; do
    jq -e --arg s "$section" '.sections[$s]' "$TMP/out.json" >/dev/null \
      || { echo "missing section: $section" >&2; false; }
  done
}

# --- human format ---

@test "human format produces readable output" {
  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" --format human > "$TMP/out.txt"
  grep -Fq "Profile Diff:" "$TMP/out.txt"
  grep -Fq "change(s) found" "$TMP/out.txt"
}

@test "human format for identical profiles" {
  bash "$DIFF" default default --plugin-root "$REPO_ROOT" --format human > "$TMP/out.txt"
  grep -Fq "identical" "$TMP/out.txt"
}

# --- various profile pairs ---

@test "typescript-library vs nextjs-prototype shows framework change" {
  bash "$DIFF" typescript-library nextjs-prototype --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.sections.stack | map(select(.field == "framework")) | length > 0' "$TMP/out.json" >/dev/null
}

@test "default vs nextjs-prototype shows github changes" {
  bash "$DIFF" default nextjs-prototype --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.sections.github | length > 0' "$TMP/out.json" >/dev/null
}

@test "default vs python-cli shows commit_scopes changes" {
  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.sections.conventions | map(select(.field == "commit_scopes")) | length > 0' "$TMP/out.json" >/dev/null
}

@test "python-cli vs fastapi-service shows framework addition" {
  bash "$DIFF" python-cli fastapi-service --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.sections.stack | map(select(.field == "framework")) | length > 0' "$TMP/out.json" >/dev/null
}

# --- error cases ---

@test "nonexistent profile dies" {
  run bash "$DIFF" default nonexistent-profile-xyz --plugin-root "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "missing second argument dies" {
  run bash "$DIFF" default
  [ "$status" -ne 0 ]
}

@test "invalid format dies" {
  run bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" --format xml
  [ "$status" -ne 0 ]
}

# --- schema validation ---

@test "output validates against profile-diff schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  bash "$DIFF" default python-cli --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/profile-diff.schema.json" "$TMP/out.json"
}
