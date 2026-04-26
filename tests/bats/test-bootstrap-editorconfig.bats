#!/usr/bin/env bats
# bin/bootstrap.sh — .editorconfig is only written when the ActionPlan
# declares it. Enforces preview-before-mutate: nothing the skill didn't
# surface to the user in the plan gets written.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  # Profile declares editorconfig=true; jsts fixture gives us a real
  # stack to bootstrap against.
  PROFILE="${REPO_ROOT}/profiles/typescript-library.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$PROFILE" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
}

teardown() { rm -rf "$TMP"; }

# Compute the canonical SHA-256 of a plan file the way bootstrap expects.
plan_sha() { bash "$PREVIEW" --plan "$1" --emit-sha256 2>/dev/null; }

@test ".editorconfig NOT written when absent from plan writes[]" {
  # Plan declares no .editorconfig entry → bootstrap must not create one
  # even though profile.extras.editorconfig=true.
  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.editorconfig" ]
  # Should emit a warning so the skill-layer author can spot the gap.
  echo "$output" | grep -Fq "not in the ActionPlan"
}

@test ".editorconfig IS written when declared in plan writes[]" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".editorconfig","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.editorconfig" ]
  grep -Fq 'nyann-managed' "$REPO/.editorconfig"
}

@test "existing .editorconfig is never overwritten" {
  # User's file must survive regardless of plan content.
  echo "# user-owned" > "$REPO/.editorconfig"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".editorconfig","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  grep -Fxq "# user-owned" "$REPO/.editorconfig"
}
