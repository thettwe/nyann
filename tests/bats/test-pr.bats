#!/usr/bin/env bats
# bin/pr.sh — context gathering + guard behavior.
# Network-dependent create path is not exercised; those tests would need
# a mocked gh binary and a fake remote.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PR="${REPO_ROOT}/bin/pr.sh"
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

@test "--context-only emits branch + commits + suggested title" {
  repo=$(make_repo_with_feature_branch)
  run bash "$PR" --target "$repo" --context-only
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.head')"            = "feat/x" ]
  [ "$(echo "$output" | jq -r '.base')"            = "main" ]
  [ "$(echo "$output" | jq -r '.suggested_title')" = "feat: add x" ]
  [ "$(echo "$output" | jq '.commits | length')"   -eq 1 ]
  [ "$(echo "$output" | jq '.ahead')"              -eq 1 ]
}

@test "--context-only with no remote still emits context (has_remote=false)" {
  repo=$(make_repo_with_feature_branch)
  run bash "$PR" --target "$repo" --context-only
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.has_remote')" = "false" ]
}

@test "--context-only works with no gh on PATH (no auth check fires)" {
  # Lock the docstring's promise: context-only doesn't need gh.
  # Earlier the SKILL/header doc claimed "no network calls AFTER the
  # gh auth check" — but the script actually exits with the JSON
  # before hitting the gh guard. So context-only should succeed even
  # when gh is unreachable. Strip PATH down to minimum so command -v
  # gh returns false.
  repo=$(make_repo_with_feature_branch)
  empty_bin=$(mktemp -d)
  ln -s "$(command -v bash)"  "$empty_bin/bash"
  ln -s "$(command -v git)"   "$empty_bin/git"
  ln -s "$(command -v jq)"    "$empty_bin/jq"
  ln -s "$(command -v sed)"   "$empty_bin/sed"
  ln -s "$(command -v awk)"   "$empty_bin/awk"
  ln -s "$(command -v grep)"  "$empty_bin/grep"
  ln -s "$(command -v tr)"    "$empty_bin/tr"
  ln -s "$(command -v cat)"   "$empty_bin/cat"
  ln -s "$(command -v cut)"   "$empty_bin/cut"
  ln -s "$(command -v head)"  "$empty_bin/head"
  ln -s "$(command -v wc)"    "$empty_bin/wc"
  ln -s "$(command -v dirname)" "$empty_bin/dirname"
  ln -s "$(command -v basename)" "$empty_bin/basename"
  # Deliberately omit `gh` so command -v gh returns false.
  run env -i HOME="$HOME" PATH="$empty_bin" bash "$PR" --target "$repo" --context-only
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.head')" = "feat/x" ]
  rm -rf "$empty_bin"
}

@test "refuses to run from main (exit 2)" {
  repo=$(make_repo_with_feature_branch)
  ( cd "$repo" && git checkout -q main )
  run bash "$PR" --target "$repo" --context-only
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "cannot open PR from main"
}

@test "refuses outside a git repo (exit 2)" {
  run bash "$PR" --target "$TMP" --context-only
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "not a git repo"
}

@test "create path without gh on PATH emits skip record" {
  repo=$(make_repo_with_feature_branch)
  # Add a fake origin so has_remote is true (we want the skip to come from
  # the gh guard, not the no-remote guard).
  ( cd "$repo" && git remote add origin "https://github.com/fake/fake.git" )
  # Point --gh at a nonexistent binary so command -v fails. Drop stderr so
  # the nyann::warn line doesn't pollute the jq input.
  out=$(bash "$PR" --target "$repo" --title "feat: x" --gh "/tmp/definitely-not-gh-$$" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.skipped')" = "pr" ]
  [ "$(echo "$out" | jq -r '.reason')"  = "gh-not-installed" ]
}

@test "create path without --title (and not --context-only) dies" {
  repo=$(make_repo_with_feature_branch)
  ( cd "$repo" && git remote add origin "https://github.com/fake/fake.git" )
  # Use a fake gh that always succeeds for `auth status` so we get past the
  # guard and hit the --title check.
  fake_gh="$TMP/fake-gh"
  cat > "$fake_gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "auth" && "$2" == "status" ]] && exit 0
exit 1
EOF
  chmod +x "$fake_gh"
  run bash "$PR" --target "$repo" --gh "$fake_gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--title is required"
}

# ---- --auto-merge ---------------------------------------------------------
# After `gh pr create` succeeds, --auto-merge runs `gh pr merge --auto`
# with the strategy from --auto-merge-strategy or .github.auto_merge_strategy
# (default squash). Output JSON gains an `auto_merge` field with the
# strategy and outcome. Failure of the auto-merge call is reported as
# {outcome: "failed", reason: "..."} — the create itself still succeeds.

# Mock gh that handles auth + push + create + merge --auto. The mock
# accepts `git push` calls because the script uses real git.
make_mock_gh_pr_create() {
  local merge_outcome="${1:-success}"  # success | failure
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
case "\$1" in
  auth) exit 0 ;;
  pr)
    case "\$2" in
      create) echo 'https://github.com/fake/fake/pull/42'; exit 0 ;;
      merge)
        if [ "${merge_outcome}" = "success" ]; then exit 0; fi
        echo 'auto-merge is not allowed on this repo' >&2
        exit 1 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "--auto-merge: enabled outcome reports strategy + URL" {
  repo=$(make_repo_with_feature_branch)
  # Use a real local bare repo as origin so git push actually succeeds.
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh_pr_create success
  out=$(bash "$PR" --target "$repo" --title "feat: x" --auto-merge --gh "$TMP/mock/gh" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.url')" = "https://github.com/fake/fake/pull/42" ]
  [ "$(echo "$out" | jq -r '.auto_merge.outcome')" = "enabled" ]
  [ "$(echo "$out" | jq -r '.auto_merge.strategy')" = "squash" ]
}

@test "--auto-merge --auto-merge-strategy rebase → strategy in output" {
  repo=$(make_repo_with_feature_branch)
  # Use a real local bare repo as origin so git push actually succeeds.
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh_pr_create success
  out=$(bash "$PR" --target "$repo" --title "feat: x" --auto-merge --auto-merge-strategy rebase --gh "$TMP/mock/gh" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.auto_merge.strategy')" = "rebase" ]
}

@test "--auto-merge: failed outcome captures reason but PR is still reported" {
  repo=$(make_repo_with_feature_branch)
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh_pr_create failure
  out=$(bash "$PR" --target "$repo" --title "feat: x" --auto-merge --gh "$TMP/mock/gh" 2>/dev/null)
  # PR URL still present (create succeeded).
  [ "$(echo "$out" | jq -r '.url')" = "https://github.com/fake/fake/pull/42" ]
  [ "$(echo "$out" | jq -r '.auto_merge.outcome')" = "failed" ]
  echo "$out" | jq -e '.auto_merge.reason | test("auto-merge")' >/dev/null
}

@test "create without --auto-merge → no auto_merge field in output (existing PrCreated shape)" {
  repo=$(make_repo_with_feature_branch)
  # Use a real local bare repo as origin so git push actually succeeds.
  origin_bare="$TMP/origin.git"
  git init -q --bare "$origin_bare"
  ( cd "$repo" && git remote add origin "$origin_bare" )
  make_mock_gh_pr_create success
  out=$(bash "$PR" --target "$repo" --title "feat: x" --gh "$TMP/mock/gh" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.url')" = "https://github.com/fake/fake/pull/42" ]
  echo "$out" | jq -e 'has("auto_merge") | not' >/dev/null
}

@test "--auto-merge-strategy invalid → dies before any network" {
  repo=$(make_repo_with_feature_branch)
  ( cd "$repo" && git remote add origin "https://github.com/fake/fake.git" )
  run bash "$PR" --target "$repo" --title "feat: x" --auto-merge --auto-merge-strategy weird-strategy --gh "$TMP/no-gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--auto-merge-strategy must be"
}
