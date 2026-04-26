#!/usr/bin/env bats
# bin/wait-for-pr-checks.sh — poll-based PR-check waiter.
# All tests use a mock gh to keep the loop deterministic and fast.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/bin/wait-for-pr-checks.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
}

teardown() { rm -rf "$TMP"; }

# Mock gh that immediately returns the given JSON for `gh pr checks <num>`.
# Use --pr 1 to skip the PR-resolution path (no `gh pr view` needed).
make_mock_gh() {
  local checks_json="$1"
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
case "\$1" in
  auth) exit 0 ;;
  pr)
    case "\$2" in
      checks) echo '${checks_json}'; exit 0 ;;
      view)   echo '{"number":1}'; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "all checks pass → outcome:pass, exit 0" {
  make_mock_gh '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"},{"name":"test","status":"completed","conclusion":"success","workflow":"ci.yml"}]'
  out=$(bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 10 --interval 1 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$out" | jq -r '.summary.total')" = "2" ]
  [ "$(echo "$out" | jq -r '.summary.passing')" = "2" ]
  [ "$(echo "$out" | jq -r '.summary.failing')" = "0" ]
}

@test "any check fails → outcome:fail, exit 3" {
  make_mock_gh '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"},{"name":"test","status":"completed","conclusion":"failure","workflow":"ci.yml"}]'
  run bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 10 --interval 1
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.outcome == "fail"' >/dev/null
  echo "$output" | jq -e '.summary.failing >= 1' >/dev/null
}

@test "PR has no checks → outcome:no-checks, exit 0" {
  make_mock_gh '[]'
  out=$(bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 10 --interval 1 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "no-checks" ]
  [ "$(echo "$out" | jq -r '.summary.total')" = "0" ]
}

@test "skipped checks count as passing" {
  # `skipped` and `neutral` are non-failure conclusions; CI marks
  # conditional jobs `skipped` when their `if:` evaluates false.
  make_mock_gh '[{"name":"deploy","status":"completed","conclusion":"skipped","workflow":"ci.yml"}]'
  out=$(bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 10 --interval 1 2>/dev/null)
  [ "$(echo "$out" | jq -r '.outcome')" = "pass" ]
  [ "$(echo "$out" | jq -r '.summary.passing')" = "1" ]
}

@test "gh missing → outcome:skipped, exit 0" {
  empty_bin="$TMP/empty-bin"
  mkdir -p "$empty_bin"
  for exe in jq sed awk tr basename dirname cat head wc bash sh date sleep printf; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$empty_bin/$exe" 2>/dev/null || true
  done
  out=$(env -i HOME="$HOME" PATH="$empty_bin" bash "$SCRIPT" --target "$REPO" --pr 1 --timeout 10 --interval 1 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.skip_reason')" = "gh-not-installed" ]
}

@test "gh present but unauthed → outcome:skipped" {
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in auth) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 10 --interval 1 2>/dev/null)
  [ "$(echo "$out" | jq -r '.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.skip_reason')" = "gh-not-authenticated" ]
}

@test "PR not resolved → outcome:skipped" {
  # No --pr passed, and `gh pr view` returns no number.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  pr)
    case "$2" in
      view) echo '{}'; exit 1 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --target "$REPO" --gh "$TMP/mock/gh" --timeout 10 --interval 1 2>/dev/null)
  [ "$(echo "$out" | jq -r '.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.skip_reason')" = "pr-not-resolved" ]
}

@test "--timeout < 1 → dies" {
  run bash "$SCRIPT" --target "$REPO" --pr 1 --timeout 0
  [ "$status" -ne 0 ]
}

@test "--interval < 1 → dies" {
  run bash "$SCRIPT" --target "$REPO" --pr 1 --interval 0
  [ "$status" -ne 0 ]
}

@test "transient gh failure does NOT short-circuit to outcome:no-checks" {
  # gh returns non-zero (network hiccup, rate-limit, auth flicker).
  # The script must NOT collapse this into an empty-checks success
  # — that would let release flows proceed without ever reading the
  # actual check status. With a tight --timeout the loop should bail
  # with outcome:timeout instead of pass.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  pr)
    case "$2" in
      checks) exit 1 ;;   # Always fail — simulates persistent transient.
      view)   echo '{"number":1}'; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  # Tolerate exit 3 in the capture (timeout exits non-zero by design).
  out=$(bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 2 --interval 1 2>/dev/null || true)
  # Expect timeout, NOT no-checks.
  [ "$(echo "$out" | jq -r '.outcome')" = "timeout" ]
  # And the exit code reflects timeout (exit 3) — re-check via run.
  run bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 2 --interval 1
  [ "$status" -eq 3 ]
}

@test "transient gh failure followed by recovery returns the recovered state" {
  # First call fails, second call returns a passing check. We can't
  # easily script "alternating" mocks in pure shell, but we can use
  # a state file that flips on first read.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
state_file="$TMP/mock-state"
case "\$1" in
  auth) exit 0 ;;
  pr)
    case "\$2" in
      checks)
        if [ -f "\$state_file" ]; then
          echo '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]'
          exit 0
        fi
        # First call fails; mark recovered for next call.
        touch "\$state_file"
        exit 1 ;;
      view) echo '{"number":1}'; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 5 --interval 1 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "pass" ]
}

@test "output validates against pr-checks-result schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  make_mock_gh '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]'
  out_file="$TMP/result.json"
  bash "$SCRIPT" --target "$REPO" --pr 1 --gh "$TMP/mock/gh" --timeout 10 --interval 1 > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/pr-checks-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/pr-checks-result.schema.json" "$out_file"
  fi
}
