#!/usr/bin/env bats
# bin/doctor-ci.sh — CI governance gate tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOCTOR_CI="${REPO_ROOT}/bin/doctor-ci.sh"
  TMP=$(mktemp -d)

  # Create a minimal repo with a known profile.
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: initial"
  )
  PROFILE="${REPO_ROOT}/profiles/default.json"
}

teardown() { rm -rf "$TMP"; }

# --- basic functionality ---

@test "produces valid JSON output" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 > "$TMP/out.json" 2>/dev/null
  jq -e . "$TMP/out.json" >/dev/null
  [ "$(jq -r '.status' "$TMP/out.json")" != "null" ]
  [ "$(jq -r '.score' "$TMP/out.json")" != "null" ]
  [ "$(jq -r '.threshold' "$TMP/out.json")" != "null" ]
}

@test "default threshold is 70" {
  # Use run since default threshold may cause exit 1 on bare repos.
  run bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE"
  echo "$output" | jq -e '.threshold == 70' >/dev/null
}

@test "custom threshold is respected" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 > "$TMP/out.json" 2>/dev/null
  [ "$(jq '.threshold' "$TMP/out.json")" -eq 0 ]
}

# --- pass / fail / warn ---

@test "score above threshold → status pass, exit 0" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 > "$TMP/out.json" 2>/dev/null
  [ $? -eq 0 ]
  [ "$(jq -r '.status' "$TMP/out.json")" = "pass" ]
}

@test "score below threshold with severity block → status fail, exit 1" {
  run bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 100 --severity block
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.status' | grep -Fxq "fail"
}

@test "score below threshold with severity warn → status warn, exit 0" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 100 --severity warn > "$TMP/out.json" 2>/dev/null
  [ $? -eq 0 ]
  [ "$(jq -r '.status' "$TMP/out.json")" = "warn" ]
}

@test "severity off → status skipped, exit 0" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --severity off > "$TMP/out.json" 2>/dev/null
  [ $? -eq 0 ]
  [ "$(jq -r '.status' "$TMP/out.json")" = "skipped" ]
}

# --- ignore filter ---

@test "ignore filter raises effective score" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 > "$TMP/raw.json" 2>/dev/null
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 --ignore missing > "$TMP/filtered.json" 2>/dev/null
  raw=$(jq '.raw_score' "$TMP/raw.json")
  filtered=$(jq '.score' "$TMP/filtered.json")
  [ "$filtered" -ge "$raw" ]
}

@test "ignored categories appear in output" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 --ignore "orphans,stale" > "$TMP/out.json" 2>/dev/null
  [ "$(jq '.ignored_categories | length' "$TMP/out.json")" -eq 2 ]
  jq -r '.ignored_categories[]' "$TMP/out.json" | grep -Fxq "orphans"
  jq -r '.ignored_categories[]' "$TMP/out.json" | grep -Fxq "stale"
}

@test "ignored categories with spaces are trimmed" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 --ignore "orphans, stale" > "$TMP/out.json" 2>/dev/null
  [ "$(jq '.ignored_categories | length' "$TMP/out.json")" -eq 2 ]
  jq -r '.ignored_categories[]' "$TMP/out.json" | grep -Fxq "stale"
}

# --- annotations ---

@test "annotations flag emits GitHub Actions workflow commands to stderr" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 --annotations \
    > "$TMP/out.json" 2> "$TMP/annotations.txt"
  jq -e . "$TMP/out.json" >/dev/null
  if [ -s "$TMP/annotations.txt" ]; then
    grep -q "^::" "$TMP/annotations.txt"
  fi
}

@test "annotation count matches actual annotations emitted" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 --annotations \
    > "$TMP/out.json" 2> "$TMP/annotations.txt"
  json_count=$(jq '.annotation_count' "$TMP/out.json")
  actual_count=$(grep -c "^::" "$TMP/annotations.txt" 2>/dev/null || echo 0)
  [ "$json_count" -eq "$actual_count" ]
}

# --- comment file ---

@test "comment file is written when --comment-file is passed" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 \
    --comment-file "$TMP/comment.md" > /dev/null 2>&1
  [ -f "$TMP/comment.md" ]
  grep -Fq "nyann governance" "$TMP/comment.md"
  grep -Fq "Threshold" "$TMP/comment.md"
}

@test "comment file contains category table" {
  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 \
    --comment-file "$TMP/comment.md" > /dev/null 2>&1
  grep -Fq "| Category |" "$TMP/comment.md"
}

# --- profile governance config ---

@test "profile governance threshold overrides default" {
  jq '. + {governance: {threshold: 40}}' "$PROFILE" > "$TMP/gov-profile.json"
  bash "$DOCTOR_CI" --target "$REPO" --profile "$TMP/gov-profile.json" > "$TMP/out.json" 2>/dev/null
  [ "$(jq '.threshold' "$TMP/out.json")" -eq 40 ]
}

@test "CLI threshold overrides profile governance threshold" {
  jq '. + {governance: {threshold: 90}}' "$PROFILE" > "$TMP/gov-profile.json"
  bash "$DOCTOR_CI" --target "$REPO" --profile "$TMP/gov-profile.json" --threshold 0 > "$TMP/out.json" 2>/dev/null
  [ "$(jq '.threshold' "$TMP/out.json")" -eq 0 ]
}

@test "explicit CLI threshold=70 is not overridden by profile" {
  jq '. + {governance: {threshold: 40}}' "$PROFILE" > "$TMP/gov-profile.json"
  run bash "$DOCTOR_CI" --target "$REPO" --profile "$TMP/gov-profile.json" --threshold 70
  echo "$output" | jq -e '.threshold == 70' >/dev/null
}

@test "profile governance severity is respected" {
  jq '. + {governance: {severity: "warn"}}' "$PROFILE" > "$TMP/gov-profile.json"
  bash "$DOCTOR_CI" --target "$REPO" --profile "$TMP/gov-profile.json" \
    --threshold 100 > "$TMP/out.json" 2>/dev/null
  [ $? -eq 0 ]
  [ "$(jq -r '.severity' "$TMP/out.json")" = "warn" ]
}

# --- error cases ---

@test "not a git repo dies" {
  run bash "$DOCTOR_CI" --target "$TMP" --profile "$PROFILE"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "not a git repo"
}

@test "missing profile dies" {
  run bash "$DOCTOR_CI" --target "$REPO" --profile "$TMP/nonexistent.json"
  [ "$status" -ne 0 ]
}

@test "invalid threshold dies" {
  run bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold abc
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "threshold"
}

@test "invalid severity dies" {
  run bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --severity nope
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "severity"
}

# --- schema validation ---

@test "output validates against governance-ci-result schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --threshold 0 > "$TMP/out.json" 2>/dev/null
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/governance-ci-result.schema.json" "$TMP/out.json"
}

@test "skipped output validates against governance-ci-result schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  bash "$DOCTOR_CI" --target "$REPO" --profile "$PROFILE" --severity off > "$TMP/out.json" 2>/dev/null
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/governance-ci-result.schema.json" "$TMP/out.json"
}
