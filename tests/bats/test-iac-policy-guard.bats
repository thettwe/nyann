#!/usr/bin/env bats
# OPA/Conftest policy gate (bin/guards/iac-policy.sh). conftest is a PATH
# stub driven by $CONFTEST_FIXTURE; covers both modes (file mode for the
# pre-action guard — filesystem-only by design — and --plan-file mode for
# the iac skills), the silent soft-skips, and the GuardResult fragments.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-iacpol.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m seed )
  GUARD="$REPO_ROOT/bin/guards/iac-policy.sh"

  mkdir -p "$REPO/.nyann/policies"
  echo 'package main' > "$REPO/.nyann/policies/base.rego"

  STUB="$TMP/stub"
  mkdir -p "$STUB"
  cat > "$STUB/conftest" <<'SH'
#!/usr/bin/env bash
printf 'conftest %s\n' "$*" >> "${CONFTEST_LOG:-/dev/null}"
cat "$CONFTEST_FIXTURE" 2>/dev/null || echo "[]"
SH
  chmod +x "$STUB/conftest"
  export CONFTEST_FIXTURE="$TMP/result.json"
  export CONFTEST_LOG="$TMP/conftest.log"
}

teardown() { rm -rf "$TMP"; }

# fixture <failures-count> [warnings-count] — a one-file conftest result.
fixture() {
  jq -n --argjson f "${1:-0}" --argjson w "${2:-0}" \
    '[{filename: "x", successes: 1,
       failures: [range($f) | {msg: "violation \(.)"}],
       warnings: [range($w) | {msg: "warning \(.)"}]}]' > "$CONFTEST_FIXTURE"
}

# branch_change <file> — commit a base, branch, and change an IaC file.
branch_change() {
  ( cd "$REPO" \
      && git checkout -q -b feat/x \
      && mkdir -p "$(dirname "$1")" && echo 'resource {}' > "$1" \
      && git add "$1" && git commit -q -m "feat: iac change" )
}

guard() { PATH="$STUB:$PATH" bash "$GUARD" "$REPO" main "$@"; }

@test "conftest absent → silent pass with skipped:true" {
  run bash "$GUARD" "$REPO" main
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
  echo "$output" | jq -r '.message' | grep -q "conftest not installed"
}

@test "no .rego policies → silent pass with skipped:true" {
  rm -f "$REPO/.nyann/policies/"*.rego
  run guard
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
  echo "$output" | jq -r '.message' | grep -q "no policies"
}

@test "no changed IaC files → silent pass with skipped:true" {
  fixture 0
  run guard
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
  echo "$output" | jq -r '.message' | grep -q "no IaC file changes"
}

@test "violations in changed files → pass:false advisory naming the first messages" {
  branch_change main.tf
  fixture 2
  run guard
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.pass')" = "false" ]
  [ "$(echo "$output" | jq -r '.severity')" = "advisory" ]
  echo "$output" | jq -r '.message' | grep -q "2 policy violation(s) \[files\]"
  echo "$output" | jq -r '.message' | grep -q "violation 0"
  grep -q "main.tf" "$CONFTEST_LOG"
}

@test "clean run over changed files → pass:true [files]" {
  branch_change infra/vpc.yaml
  fixture 0
  run guard
  [ "$(echo "$output" | jq -r '.pass')" = "true" ]
  echo "$output" | jq -r '.message' | grep -q "policies passed \[files\]"
}

@test "warnings only → pass:true with the warning count" {
  branch_change main.tf
  fixture 0 3
  run guard
  [ "$(echo "$output" | jq -r '.pass')" = "true" ]
  echo "$output" | jq -r '.message' | grep -q "3 warning(s)"
}

@test "workflow YAML under .github/ is never evaluated" {
  branch_change .github/workflows/deploy.yml
  fixture 1
  run guard
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
  [ ! -f "$CONFTEST_LOG" ]
}

@test "profile guards.iac_policy_dir overrides the policy root" {
  mkdir -p "$REPO/infra/policies"
  mv "$REPO/.nyann/policies/base.rego" "$REPO/infra/policies/base.rego"
  jq -n '{guards: {iac_policy_dir: "infra/policies"}}' > "$TMP/profile.json"
  branch_change main.tf
  fixture 1
  run guard "$TMP/profile.json"
  [ "$(echo "$output" | jq -r '.pass')" = "false" ]
  grep -q -- "--policy $REPO/infra/policies" "$CONFTEST_LOG"
}

@test "missing base falls back to all tracked IaC files" {
  ( cd "$REPO" && echo 'resource {}' > main.tf && git add main.tf && git commit -q -m "feat: tf" )
  fixture 1
  run bash -c 'PATH="$1:$PATH" bash "$2" "$3" no-such-base' _ "$STUB" "$GUARD" "$REPO"
  [ "$(echo "$output" | jq -r '.pass')" = "false" ]
  grep -q "main.tf" "$CONFTEST_LOG"
}

@test "plan mode: violations against the IacPlan JSON → pass:false [plan]" {
  jq -n '{tool: "terraform", summary: {add: 1, change: 0, destroy: 2}, destructive: true}' > "$TMP/plan.json"
  fixture 1
  run bash -c 'PATH="$1:$PATH" bash "$2" --plan-file "$3" --target "$4"' _ "$STUB" "$GUARD" "$TMP/plan.json" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.pass')" = "false" ]
  echo "$output" | jq -r '.message' | grep -q "\[plan\]"
  grep -q -- "- $" "$CONFTEST_LOG" || grep -qE -- "-$" "$CONFTEST_LOG"
}

@test "plan mode: unreadable plan file → silent skip" {
  run bash -c 'PATH="$1:$PATH" bash "$2" --plan-file "$3" --target "$4"' _ "$STUB" "$GUARD" "$TMP/ghost.json" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
}

@test "unparseable conftest output → silent skip, never a failure" {
  branch_change main.tf
  echo "garbage not json" > "$CONFTEST_FIXTURE"
  run guard
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
}

@test "fragment shape matches the GuardResult contract" {
  branch_change main.tf
  fixture 1
  run guard
  [ "$(echo "$output" | jq -r 'keys - ["message","name","pass","severity","skipped"] | length')" = "0" ]
  [ "$(echo "$output" | jq -r '.name')" = "iac-policy" ]
}
