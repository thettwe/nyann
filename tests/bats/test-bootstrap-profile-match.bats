#!/usr/bin/env bats
# bin/bootstrap.sh — profile/stack mismatch warning.
# The warning is advisory only (stderr), bootstrap continues either way.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# Compute the canonical SHA-256 of a plan file the way bootstrap expects.
plan_sha() { bash "$PREVIEW" --plan "$1" --emit-sha256 2>/dev/null; }

prepare_target() {
  # Minimal fixture: an empty jsts repo with a matching stack.json and a
  # trivial plan + docplan. bootstrap.sh doesn't actually need to finish
  # successfully — we only check stderr for the warning before any writes.
  local repo="$TMP/repo"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main )
  cp -r "${REPO_ROOT}/tests/fixtures/jsts-empty/." "$repo/" 2>/dev/null || true
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/default.json" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$repo" > "$TMP/stack.json"
  echo "$repo"
}

@test "warns when --profile default runs against a confidently-detected stack" {
  repo=$(prepare_target)
  # jsts-empty is detected as TypeScript; using default.json should warn.
  run bash "$BOOTSTRAP" \
    --target "$repo" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --project-name test-warn
  # We don't care about the final exit status for this test (might fail on
  # missing git identity or similar in sandbox). We only check that the
  # warning is on stderr before any halting errors.
  echo "$output" | grep -Fq "stack-agnostic (default)"
  echo "$output" | grep -Fq "typescript"
}

@test "no warning when profile and stack agree" {
  repo=$(prepare_target)
  # nextjs-prototype declares typescript, matches jsts-empty detection.
  run bash "$BOOTSTRAP" \
    --target "$repo" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --project-name test-match
  # Negative assertion: the specific warning strings must NOT appear.
  ! echo "$output" | grep -Fq "stack-agnostic (default)"
  ! echo "$output" | grep -Fq "profile targets"
}

@test "warns when profile targets a different language than detection" {
  repo=$(prepare_target)
  # python-cli declares python; jsts fixture detects typescript. Mismatch.
  run bash "$BOOTSTRAP" \
    --target "$repo" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "${REPO_ROOT}/profiles/python-cli.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --project-name test-mismatch
  echo "$output" | grep -Fq "targets python"
  echo "$output" | grep -Fq "identified typescript"
}
