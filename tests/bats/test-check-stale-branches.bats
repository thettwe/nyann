#!/usr/bin/env bats
# bin/check-stale-branches.sh — local-branch hygiene audit.
# Categorises branches into merged_into_base + stale_unmerged sets.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/bin/check-stale-branches.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
}

teardown() { rm -rf "$TMP"; }

# Cross-platform "N days ago" timestamp generator (BSD vs GNU date).
days_ago_iso() {
  local n="$1"
  if date -u -v-"${n}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then return; fi
  date -u -d "-${n} days" '+%Y-%m-%dT%H:%M:%SZ'
}

@test "empty repo (only main, no other branches) → empty arrays" {
  out=$(bash "$SCRIPT" --target "$REPO" --days 90)
  [ "$(echo "$out" | jq -r '.summary.merged_count')" = "0" ]
  [ "$(echo "$out" | jq -r '.summary.stale_count')" = "0" ]
  [ "$(echo "$out" | jq -r '.summary.skipped')" = "false" ]
  [ "$(echo "$out" | jq -r '.base_branch')" = "main" ]
}

@test "branch merged into base → categorised as merged_into_base" {
  ( cd "$REPO"
    git checkout -q -b feat/done
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: done"
    git checkout -q main
    git -c user.email=t@t -c user.name=t merge -q feat/done --no-ff -m "merge"
  )
  out=$(bash "$SCRIPT" --target "$REPO" --days 90)
  [ "$(echo "$out" | jq -r '.summary.merged_count')" = "1" ]
  [ "$(echo "$out" | jq -r '.merged_into_base[0].name')" = "feat/done" ]
  [ "$(echo "$out" | jq -r '.summary.stale_count')" = "0" ]
}

@test "old unmerged branch → categorised as stale_unmerged with days_old" {
  ts=$(days_ago_iso 95)
  ( cd "$REPO"
    git checkout -q -b feat/abandoned
    GIT_COMMITTER_DATE="$ts" GIT_AUTHOR_DATE="$ts" \
      git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "abandoned"
    git checkout -q main
  )
  out=$(bash "$SCRIPT" --target "$REPO" --days 90)
  [ "$(echo "$out" | jq -r '.summary.stale_count')" = "1" ]
  [ "$(echo "$out" | jq -r '.stale_unmerged[0].name')" = "feat/abandoned" ]
  [ "$(echo "$out" | jq -r '.stale_unmerged[0].days_old')" -ge 94 ]
}

@test "recent unmerged branch is NOT flagged" {
  ( cd "$REPO"
    git checkout -q -b feat/active
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "in progress"
    git checkout -q main
  )
  out=$(bash "$SCRIPT" --target "$REPO" --days 90)
  [ "$(echo "$out" | jq -r '.summary.merged_count')" = "0" ]
  [ "$(echo "$out" | jq -r '.summary.stale_count')" = "0" ]
}

@test "current branch is NEVER flagged regardless of age or merge state" {
  ts=$(days_ago_iso 200)
  ( cd "$REPO"
    git checkout -q -b feat/current-branch
    GIT_COMMITTER_DATE="$ts" GIT_AUTHOR_DATE="$ts" \
      git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "old current"
    # Do NOT switch back to main; current branch stays feat/current-branch.
  )
  out=$(bash "$SCRIPT" --target "$REPO" --days 90)
  # Even though feat/current-branch is 200 days old + unmerged, it's
  # the current branch and must be excluded.
  [ "$(echo "$out" | jq -r '.summary.stale_count')" = "0" ]
  [ "$(echo "$out" | jq -r '.current_branch')" = "feat/current-branch" ]
}

@test "missing base branch → soft skip with reason" {
  ( cd "$REPO" && git branch -m main trunk )
  # No 'main' branch anymore; --base main should soft-skip.
  out=$(bash "$SCRIPT" --target "$REPO" --base main --days 90)
  [ "$(echo "$out" | jq -r '.summary.skipped')" = "true" ]
  [ "$(echo "$out" | jq -r '.summary.skip_reason')" = "base branch not found locally" ]
  [ "$(echo "$out" | jq -r '.summary.merged_count')" = "0" ]
  [ "$(echo "$out" | jq -r '.summary.stale_count')" = "0" ]
}

@test "non-git directory → dies" {
  notrepo="$TMP/not-a-repo"
  mkdir -p "$notrepo"
  run bash "$SCRIPT" --target "$notrepo"
  [ "$status" -ne 0 ]
}

@test "--days non-integer → dies" {
  run bash "$SCRIPT" --target "$REPO" --days abc
  [ "$status" -ne 0 ]
}

@test "output validates against stale-branches-report schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  ( cd "$REPO"
    git checkout -q -b feat/done
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: done"
    git checkout -q main
    git -c user.email=t@t -c user.name=t merge -q feat/done --no-ff -m "merge"
  )
  out_file="$TMP/report.json"
  bash "$SCRIPT" --target "$REPO" --days 90 > "$out_file"
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/stale-branches-report.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/stale-branches-report.schema.json" "$out_file"
  fi
}
