#!/usr/bin/env bats
# bin/ship.sh — combined PR + (auto-merge OR poll-and-merge) flow.
# All network paths use a mock gh so the loop is deterministic and
# fast. Mirrors test-pr.bats / test-wait-for-pr-checks.bats setup.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SHIP="${REPO_ROOT}/bin/ship.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_repo_with_feature_branch() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    git checkout -q -b feat/x
    echo "x" > x.txt
    git -c user.email=t@t -c user.name=t add x.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat: add x"
  )
  echo "$repo"
}

# Mock gh: PR create succeeds, optional merge result, optional checks JSON.
# $1 = create_outcome (success | failure)
# $2 = merge_outcome  (success | failure)  — used by both `merge --auto` and `merge`
# $3 = checks_json    (raw JSON for `gh pr checks`)
make_mock_gh() {
  local create_outcome="${1:-success}"
  local merge_outcome="${2:-success}"
  local checks_json="${3:-[]}"
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
case "\$1" in
  auth) exit 0 ;;
  pr)
    case "\$2" in
      create)
        if [ "${create_outcome}" = "success" ]; then
          echo 'https://github.com/fake/fake/pull/42'
          exit 0
        fi
        echo 'create failed' >&2
        exit 1 ;;
      merge)
        if [ "${merge_outcome}" = "success" ]; then exit 0; fi
        echo 'merge blocked: required reviews missing' >&2
        exit 1 ;;
      checks) echo '${checks_json}'; exit 0 ;;
      view)   echo '{"number":42}'; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

# --- gh-guard / pre-flight skips -----------------------------------------

@test "gh missing → outcome:skipped, exit 0, ship-shaped JSON" {
  repo=$(make_repo_with_feature_branch)
  out=$(bash "$SHIP" --target "$repo" --title "feat: x" --gh "/tmp/definitely-not-gh-$$" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.skip_reason')" = "gh-not-installed" ]
  [ "$(echo "$out" | jq -r '.mode')" = "auto-merge" ]
}

@test "gh present but unauthed → outcome:skipped" {
  repo=$(make_repo_with_feature_branch)
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in auth) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SHIP" --target "$repo" --title "feat: x" --gh "$TMP/mock/gh" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.skip_reason')" = "gh-not-authenticated" ]
}

@test "missing --title → dies (validation precedes any network call)" {
  repo=$(make_repo_with_feature_branch)
  run bash "$SHIP" --target "$repo"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--title is required"
}

@test "invalid --merge-strategy → dies" {
  repo=$(make_repo_with_feature_branch)
  run bash "$SHIP" --target "$repo" --title "feat: x" --merge-strategy weird
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--merge-strategy must be"
}

# --- auto-merge mode (default) --------------------------------------------

@test "auto-merge happy path → outcome:queued, mode:auto-merge, exit 0" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success
  out=$(bash "$SHIP" --target "$repo" --title "feat: x" --gh "$TMP/mock/gh" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "queued" ]
  [ "$(echo "$out" | jq -r '.mode')" = "auto-merge" ]
  [ "$(echo "$out" | jq -r '.pr_url')" = "https://github.com/fake/fake/pull/42" ]
  [ "$(echo "$out" | jq -r '.pr_number')" = "42" ]
  [ "$(echo "$out" | jq -r '.merge_strategy')" = "squash" ]
}

@test "auto-merge with --merge-strategy rebase → strategy preserved in output" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success
  out=$(bash "$SHIP" --target "$repo" --title "feat: x" --merge-strategy rebase --gh "$TMP/mock/gh" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.merge_strategy')" = "rebase" ]
}

@test "auto-merge enable failure → outcome:merge-failed, exit 0, reason captured" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  # PR create succeeds, merge --auto call fails (e.g. repo doesn't allow it).
  make_mock_gh success failure
  run bash "$SHIP" --target "$repo" --title "feat: x" --gh "$TMP/mock/gh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "merge-failed"' >/dev/null
  # PR URL still present — create itself succeeded.
  echo "$output" | jq -e '.pr_url == "https://github.com/fake/fake/pull/42"' >/dev/null
  echo "$output" | jq -e '.merge_failed_reason | length > 0' >/dev/null
}

# --- client-side mode -----------------------------------------------------

@test "client-side: green CI → outcome:shipped, exit 0, checks block present" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]'
  out=$(bash "$SHIP" --target "$repo" --title "feat: x" --client-side \
    --gh "$TMP/mock/gh" --timeout 5 --interval 1 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "shipped" ]
  [ "$(echo "$out" | jq -r '.mode')" = "client-side" ]
  [ "$(echo "$out" | jq -r '.checks.outcome')" = "pass" ]
  [ "$(echo "$out" | jq -r '.checks.passing')" = "1" ]
}

@test "client-side: failing CI → outcome:ci-failed, exit 0, no merge attempted" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success '[{"name":"test","status":"completed","conclusion":"failure","workflow":"ci.yml"}]'
  run bash "$SHIP" --target "$repo" --title "feat: x" --client-side \
    --gh "$TMP/mock/gh" --timeout 5 --interval 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "ci-failed"' >/dev/null
  echo "$output" | jq -e '.checks.failing >= 1' >/dev/null
  # PR URL still present even though we didn't merge.
  echo "$output" | jq -e '.pr_url == "https://github.com/fake/fake/pull/42"' >/dev/null
}

@test "client-side: no checks attached without --allow-no-checks → outcome:ci-failed with reason" {
  # The waiter returns no-checks when the PR has zero checks. After a
  # fresh `gh pr create`, this is almost always a race: workflows
  # haven't attached yet. Default behavior must refuse to merge so the
  # gate is meaningful; the user has to opt in via --allow-no-checks
  # for legitimate no-CI repos.
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success '[]'  # empty checks
  run bash "$SHIP" --target "$repo" --title "feat: x" --client-side \
    --gh "$TMP/mock/gh" --timeout 5 --interval 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "ci-failed"' >/dev/null
  echo "$output" | jq -e '.checks.outcome == "no-checks"' >/dev/null
  echo "$output" | jq -e '.ci_failed_reason | test("--allow-no-checks")' >/dev/null
}

@test "client-side: no checks attached + --allow-no-checks → outcome:shipped (opt-in)" {
  # When the user explicitly says the empty-checks state is intentional,
  # ship.sh proceeds to merge.
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success '[]'
  out=$(bash "$SHIP" --target "$repo" --title "feat: x" --client-side \
    --allow-no-checks --gh "$TMP/mock/gh" --timeout 5 --interval 1 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.outcome')" = "shipped" ]
  [ "$(echo "$out" | jq -r '.checks.outcome')" = "no-checks" ]
  # ci_failed_reason absent on success.
  echo "$out" | jq -e 'has("ci_failed_reason") | not' >/dev/null
}

@test "client-side: green CI but merge call fails → outcome:merge-failed, reason captured" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  # CI passes; gh pr merge call returns non-zero.
  make_mock_gh success failure '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]'
  run bash "$SHIP" --target "$repo" --title "feat: x" --client-side \
    --gh "$TMP/mock/gh" --timeout 5 --interval 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "merge-failed"' >/dev/null
  echo "$output" | jq -e '.merge_failed_reason | test("required reviews|merge")' >/dev/null
}

# --- schema validation ----------------------------------------------------

@test "auto-merge output validates against ship-result schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success
  out_file="$TMP/result.json"
  bash "$SHIP" --target "$repo" --title "feat: x" --gh "$TMP/mock/gh" > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/ship-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/ship-result.schema.json" "$out_file"
  fi
}

@test "client-side shipped output validates against ship-result schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh success success '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]'
  out_file="$TMP/result.json"
  bash "$SHIP" --target "$repo" --title "feat: x" --client-side \
    --gh "$TMP/mock/gh" --timeout 5 --interval 1 > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/ship-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/ship-result.schema.json" "$out_file"
  fi
}

@test "skipped (gh missing) output validates against ship-result schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  repo=$(make_repo_with_feature_branch)
  out_file="$TMP/result.json"
  bash "$SHIP" --target "$repo" --title "feat: x" --gh "/tmp/definitely-not-gh-$$" > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/ship-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/ship-result.schema.json" "$out_file"
  fi
}
