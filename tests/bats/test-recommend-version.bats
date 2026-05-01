#!/usr/bin/env bats
# bin/recommend-version.sh — semver bump recommendation from commit history.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RV="${REPO_ROOT}/bin/recommend-version.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: initial"
  )
  echo "$repo"
}

make_tagged_repo() {
  local repo
  repo=$(make_repo)
  git -C "$repo" -c user.email=t@t -c user.name=t tag v1.2.3
  echo "$repo"
}

add_commit() {
  local repo="$1" msg="$2"
  echo "$msg" >> "$repo/changes.txt"
  git -C "$repo" add changes.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

add_commit_with_body() {
  local repo="$1" subject="$2" body="$3"
  echo "$subject" >> "$repo/changes.txt"
  git -C "$repo" add changes.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "$subject" -m "$body"
}

# --- basic functionality ---

@test "no prior tags suggests 0.1.0 first release" {
  repo=$(make_repo)
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.status')" = "no-tags" ]
  [ "$(echo "$out" | jq -r '.recommended')" = "0.1.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "first" ]
  [ "$(echo "$out" | jq '.current')" = "null" ]
}

@test "no commits since tag reports no-commits with bump none" {
  repo=$(make_tagged_repo)
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.status')" = "no-commits" ]
  [ "$(echo "$out" | jq -r '.current')" = "1.2.3" ]
  [ "$(echo "$out" | jq -r '.bump')" = "none" ]
  [ "$(echo "$out" | jq '.counts.total')" -eq 0 ]
}

@test "fix-only commits suggest patch bump" {
  repo=$(make_tagged_repo)
  add_commit "$repo" "fix: correct typo"
  add_commit "$repo" "fix(db): repair migration"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.status')" = "ok" ]
  [ "$(echo "$out" | jq -r '.recommended')" = "1.2.4" ]
  [ "$(echo "$out" | jq -r '.bump')" = "patch" ]
  [ "$(echo "$out" | jq '.counts.fix')" -eq 2 ]
  [ "$(echo "$out" | jq '.counts.total')" -eq 2 ]
}

@test "feat commits suggest minor bump" {
  repo=$(make_tagged_repo)
  add_commit "$repo" "feat: add new endpoint"
  add_commit "$repo" "fix: typo"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.recommended')" = "1.3.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "minor" ]
  [ "$(echo "$out" | jq '.counts.feat')" -eq 1 ]
  [ "$(echo "$out" | jq '.counts.fix')" -eq 1 ]
}

@test "breaking change suggests major bump" {
  repo=$(make_tagged_repo)
  add_commit "$repo" "feat(api)!: remove legacy route"
  add_commit "$repo" "feat: add new route"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.recommended')" = "2.0.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "major" ]
  [ "$(echo "$out" | jq '.counts.breaking')" -eq 1 ]
}

@test "breaking change in pre-1.0 bumps minor not major" {
  repo="$TMP/pre1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: init"
    git -c user.email=t@t -c user.name=t tag v0.3.1
  )
  add_commit "$repo" "feat(api)!: breaking change"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.recommended')" = "0.4.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "minor" ]
  echo "$out" | jq -r '.reason' | grep -F "pre-1.0"
}

@test "non-conventional commits count as other → patch bump" {
  repo=$(make_tagged_repo)
  add_commit "$repo" "updated readme"
  add_commit "$repo" "misc cleanup"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.recommended')" = "1.2.4" ]
  [ "$(echo "$out" | jq -r '.bump')" = "patch" ]
  [ "$(echo "$out" | jq '.counts.other')" -eq 2 ]
}

@test "mixed commits pick the highest bump" {
  repo=$(make_tagged_repo)
  add_commit "$repo" "fix: small fix"
  add_commit "$repo" "feat: new thing"
  add_commit "$repo" "docs: update readme"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.recommended')" = "1.3.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "minor" ]
}

# --- custom tag prefix ---

@test "custom tag prefix finds correct latest tag" {
  repo="$TMP/prefix"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: init"
    git -c user.email=t@t -c user.name=t tag api-v2.0.0
  )
  add_commit "$repo" "feat: new api feature"
  out=$(bash "$RV" --target "$repo" --tag-prefix "api-v")
  [ "$(echo "$out" | jq -r '.current')" = "2.0.0" ]
  [ "$(echo "$out" | jq -r '.recommended')" = "2.1.0" ]
}

# --- error cases ---

@test "not a git repo dies" {
  run bash "$RV" --target "$TMP"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "not a git repo"
}

@test "missing target directory dies" {
  run bash "$RV" --target "$TMP/nonexistent"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "must be a directory"
}

@test "unknown argument dies" {
  repo=$(make_repo)
  run bash "$RV" --target "$repo" --bogus
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "unknown argument"
}

# --- first release with commits ---

@test "BREAKING CHANGE footer in body triggers major bump" {
  repo=$(make_tagged_repo)
  add_commit_with_body "$repo" "feat: add api" "BREAKING CHANGE: remove old route"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.recommended')" = "2.0.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "major" ]
  [ "$(echo "$out" | jq '.counts.breaking')" -eq 1 ]
}

@test "BREAKING-CHANGE footer (hyphen variant) triggers major bump" {
  repo=$(make_tagged_repo)
  add_commit_with_body "$repo" "fix: update handler" "BREAKING-CHANGE: new required parameter"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.bump')" = "major" ]
  [ "$(echo "$out" | jq '.counts.breaking')" -eq 1 ]
}

@test "--from overrides log range but still resolves current version from tags" {
  repo=$(make_tagged_repo)
  add_commit "$repo" "feat: feature one"
  add_commit "$repo" "feat: feature two"
  from_sha=$(git -C "$repo" rev-parse HEAD~1)
  out=$(bash "$RV" --target "$repo" --from "$from_sha")
  [ "$(echo "$out" | jq -r '.current')" = "1.2.3" ]
  [ "$(echo "$out" | jq -r '.status')" = "ok" ]
  [ "$(echo "$out" | jq '.counts.total')" -eq 1 ]
  [ "$(echo "$out" | jq -r '.recommended')" = "1.3.0" ]
}

@test "first release with commits suggests 0.1.0" {
  repo=$(make_repo)
  add_commit "$repo" "feat: initial feature"
  add_commit "$repo" "fix: small fix"
  out=$(bash "$RV" --target "$repo")
  [ "$(echo "$out" | jq -r '.status')" = "no-tags" ]
  [ "$(echo "$out" | jq -r '.recommended')" = "0.1.0" ]
  [ "$(echo "$out" | jq -r '.bump')" = "first" ]
  [ "$(echo "$out" | jq '.counts.total')" -eq 3 ]
}

# --- schema validation ---

@test "output validates against version-recommendation schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  repo=$(make_tagged_repo)
  add_commit "$repo" "feat: something"
  bash "$RV" --target "$repo" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/version-recommendation.schema.json" "$TMP/out.json"
}

@test "no-commits output validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  repo=$(make_tagged_repo)
  bash "$RV" --target "$repo" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/version-recommendation.schema.json" "$TMP/out.json"
}

@test "no-tags output validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  repo=$(make_repo)
  bash "$RV" --target "$repo" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/version-recommendation.schema.json" "$TMP/out.json"
}
