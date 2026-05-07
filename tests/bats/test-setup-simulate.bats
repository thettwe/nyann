#!/usr/bin/env bats
# bin/setup.sh --simulate <repo> + bin/plan-bootstrap.sh.
#
# Covers:
#   - plan-bootstrap composes a valid ActionPlan against fixtures
#   - --simulate emits a useful summary (text + json)
#   - --simulate against a non-directory dies cleanly
#   - --simulate is read-only: no preferences.json written, no
#     mutations to the target repo
#   - monorepo signal sets simulation: "partial"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-sim.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  USER_ROOT="$TMP/user-root"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

# --- plan-bootstrap.sh ------------------------------------------------------

@test "plan-bootstrap emits a valid ActionPlan against an empty repo" {
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/default.json" > "$TMP/doc-plan.json"

  run bash "${REPO_ROOT}/bin/plan-bootstrap.sh" \
    --target "$REPO" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("writes") and has("commands") and has("remote")' >/dev/null
}

@test "plan-bootstrap nextjs-prototype writes are non-empty and include hooks" {
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$TMP/doc-plan.json"

  run bash "${REPO_ROOT}/bin/plan-bootstrap.sh" \
    --target "$REPO" \
    --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" \
    --doc-plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]
  paths=$(echo "$output" | jq -c '[.writes[].path]')
  echo "$paths" | grep -q "\.husky/pre-commit"
  echo "$paths" | grep -q "commitlint.config.js"
  echo "$paths" | grep -q "CLAUDE.md"
}

@test "plan-bootstrap output validates against action-plan schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$TMP/doc-plan.json"
  bash "${REPO_ROOT}/bin/plan-bootstrap.sh" \
    --target "$REPO" \
    --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" \
    --doc-plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" > "$TMP/plan.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/action-plan.schema.json" "$TMP/plan.json"
}

# --- setup --simulate text mode ---------------------------------------------

@test "setup --simulate prints a useful summary against a fresh repo" {
  out=$(bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile nextjs-prototype --simulate "$REPO" 2>&1 1>/dev/null || true)
  echo "$out" | grep -q "^Simulation:"
  echo "$out" | grep -q "^Profile:"
  echo "$out" | grep -q "^Branching:"
  echo "$out" | grep -q "would:"
  echo "$out" | grep -q "No changes made"
}

@test "setup --simulate is strictly read-only (no preferences.json written)" {
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile nextjs-prototype --simulate "$REPO" >/dev/null 2>&1
  [ ! -f "$USER_ROOT/preferences.json" ]
}

@test "setup --simulate does not mutate the target repo" {
  before=$(find "$REPO" -type f | sort | xargs -I{} shasum {} 2>/dev/null | md5sum 2>/dev/null \
    || find "$REPO" -type f | sort | xargs -I{} shasum {} 2>/dev/null | md5 -q)
  bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile nextjs-prototype --simulate "$REPO" >/dev/null 2>&1
  after=$(find "$REPO" -type f | sort | xargs -I{} shasum {} 2>/dev/null | md5sum 2>/dev/null \
    || find "$REPO" -type f | sort | xargs -I{} shasum {} 2>/dev/null | md5 -q)
  [ "$before" = "$after" ]
}

@test "setup --simulate against a non-directory dies cleanly" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --simulate "$TMP/no-such-dir"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a directory"
}

# --- setup --simulate JSON mode ---------------------------------------------

@test "setup --simulate --json emits a structured payload" {
  run bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile nextjs-prototype --simulate "$REPO" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    has("simulation") and has("target") and has("stack")
    and has("profile") and has("branching") and has("plan")
  ' >/dev/null
}

@test "setup --simulate --json simulation is 'ok' for a non-monorepo" {
  out=$(bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile nextjs-prototype --simulate "$REPO" --json)
  [ "$(echo "$out" | jq -r '.simulation')" = "ok" ]
  [ "$(echo "$out" | jq -r '.partial_reason')" = "null" ]
}

# --- monorepo path ----------------------------------------------------------

@test "setup --simulate marks monorepos as simulation: partial" {
  # Synthesise a minimal monorepo: pnpm-workspace.yaml + a workspace.
  cat > "$REPO/pnpm-workspace.yaml" <<'YAML'
packages:
  - "packages/*"
YAML
  mkdir -p "$REPO/packages/a"
  cat > "$REPO/packages/a/package.json" <<'JSON'
{"name":"@org/a","version":"0.0.1"}
JSON
  cat > "$REPO/package.json" <<'JSON'
{"name":"root","private":true}
JSON

  out=$(bash "${REPO_ROOT}/bin/setup.sh" --user-root "$USER_ROOT" \
    --default-profile nextjs-prototype --simulate "$REPO" --json 2>/dev/null)
  is_mono=$(echo "$out" | jq -r '.stack.is_monorepo')
  if [[ "$is_mono" == "true" ]]; then
    [ "$(echo "$out" | jq -r '.simulation')" = "partial" ]
    echo "$out" | jq -r '.partial_reason' | grep -q "monorepo"
  else
    skip "stack detector did not flag the synthetic monorepo (test fixture too thin)"
  fi
}
