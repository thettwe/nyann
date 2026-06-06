#!/usr/bin/env bats
# test-pr-risk-score.bats — tests for PR risk scoring (E2).

setup() {
  export RISK="${BATS_TEST_DIRNAME}/../../bin/pr-risk-score.sh"
  export TMP="${BATS_TEST_TMPDIR}"
}

make_repo_with_branch() {
  local d="$TMP/repo-$$-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$d/src" "$d/tests"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"
  echo 'main' > "$d/src/app.ts"
  echo 'test' > "$d/tests/app.test.ts"
  git -C "$d" add .
  git -C "$d" commit -qm "feat: initial"
  git -C "$d" checkout -qb feature
  echo "$d"
}

@test "low risk: small change with matching test" {
  repo=$(make_repo_with_branch)
  echo 'updated' >> "$repo/src/app.ts"
  echo 'updated' >> "$repo/tests/app.test.ts"
  git -C "$repo" add .
  git -C "$repo" commit -qm "fix: small fix"

  result=$(bash "$RISK" --target "$repo" --base main 2>/dev/null)
  score=$(echo "$result" | jq '.score')
  level=$(echo "$result" | jq -r '.level')
  [ "$score" -le 60 ]
  echo "$result" | jq -e '.breakdown.churn.files_changed == 2'
}

@test "higher risk: many source changes without tests" {
  repo=$(make_repo_with_branch)
  for i in $(seq 1 10); do
    echo "module $i" > "$repo/src/mod${i}.ts"
  done
  git -C "$repo" add .
  git -C "$repo" commit -qm "feat: add 10 modules"

  result=$(bash "$RISK" --target "$repo" --base main 2>/dev/null)
  echo "$result" | jq -e '.breakdown.test_gap.source_changes >= 10'
  echo "$result" | jq -e '.breakdown.test_gap.untested_changes | length >= 10'
}

@test "health delta: no health file → neutral signal" {
  repo=$(make_repo_with_branch)
  echo 'x' >> "$repo/src/app.ts"
  git -C "$repo" add .
  git -C "$repo" commit -qm "fix: tiny"

  result=$(bash "$RISK" --target "$repo" --base main 2>/dev/null)
  echo "$result" | jq -e '.breakdown.health_delta.current == 0'
  echo "$result" | jq -e '.breakdown.health_delta.previous == 0'
}

@test "health delta: regressing score increases risk" {
  repo=$(make_repo_with_branch)
  echo 'x' >> "$repo/src/app.ts"
  git -C "$repo" add .
  git -C "$repo" commit -qm "fix: tiny"

  mkdir -p "$repo/memory"
  cat > "$repo/memory/health.json" <<'JSON'
{"scores":[{"score":90,"timestamp":"2026-01-01"},{"score":70,"timestamp":"2026-01-15"}]}
JSON

  result=$(bash "$RISK" --target "$repo" --base main --health-file "$repo/memory/health.json" 2>/dev/null)
  echo "$result" | jq -e '.breakdown.health_delta.delta == -20'
  echo "$result" | jq -e '.breakdown.health_delta.score > 50'
}

# ── BUG D regression: float health score must not abort arithmetic ──────────
# .scores[].score can be a float (e.g. 70.5). Feeding it to bash $((...)) aborts
# under set -euo pipefail with "invalid arithmetic operator". The script must
# coerce to integer (floor) and still produce a valid result.

@test "health delta: float scores do not abort the script" {
  repo=$(make_repo_with_branch)
  echo 'x' >> "$repo/src/app.ts"
  git -C "$repo" add .
  git -C "$repo" commit -qm "fix: tiny"

  mkdir -p "$repo/memory"
  cat > "$repo/memory/health.json" <<'JSON'
{"scores":[{"score":90.5,"timestamp":"2026-01-01"},{"score":70.2,"timestamp":"2026-01-15"}]}
JSON

  run bash "$RISK" --target "$repo" --base main --health-file "$repo/memory/health.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -vq "invalid arithmetic"
  # floor(70.2) - floor(90.5) = 70 - 90 = -20
  echo "$output" | jq -e '.breakdown.health_delta.current == 70'
  echo "$output" | jq -e '.breakdown.health_delta.previous == 90'
  echo "$output" | jq -e '.breakdown.health_delta.delta == -20'
  echo "$output" | jq -e '.score | type == "number"'
}

@test "output validates level thresholds" {
  repo=$(make_repo_with_branch)
  echo 'x' >> "$repo/src/app.ts"
  git -C "$repo" add .
  git -C "$repo" commit -qm "fix: tiny"

  result=$(bash "$RISK" --target "$repo" --base main 2>/dev/null)
  score=$(echo "$result" | jq '.score')
  level=$(echo "$result" | jq -r '.level')

  if (( score <= 30 )); then [ "$level" = "low" ]; fi
  if (( score > 30 && score <= 60 )); then [ "$level" = "medium" ]; fi
  if (( score > 60 && score <= 80 )); then [ "$level" = "high" ]; fi
  if (( score > 80 )); then [ "$level" = "critical" ]; fi
}

@test "recommendations when untested changes exist" {
  repo=$(make_repo_with_branch)
  echo 'new' > "$repo/src/untested.ts"
  git -C "$repo" add .
  git -C "$repo" commit -qm "feat: untested"

  result=$(bash "$RISK" --target "$repo" --base main 2>/dev/null)
  echo "$result" | jq -e '.recommendations | length >= 1'
  echo "$result" | jq -e '.recommendations[0] | test("coverage")'
}

@test "no changes → low score" {
  repo=$(make_repo_with_branch)
  result=$(bash "$RISK" --target "$repo" --base main 2>/dev/null)
  echo "$result" | jq -e '.score <= 30'
  echo "$result" | jq -e '.level == "low"'
  echo "$result" | jq -e '.breakdown.churn.files_changed == 0'
}

@test "not a git repo → error" {
  d="$TMP/notgit-$$"
  mkdir -p "$d"
  run bash "$RISK" --target "$d"
  [ "$status" -ne 0 ]
}
