#!/usr/bin/env bats
# bin/cleanup-branches.sh — preview-then-mutate prune of merged
# local branches. Mirrors the --yes contract used by undo and
# switch-profile.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/bin/cleanup-branches.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
}

teardown() { rm -rf "$TMP"; }

# Plant a branch that's been merged into main.
plant_merged() {
  local name="$1"
  ( cd "$REPO"
    git checkout -q -b "$name"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: $name"
    git checkout -q main
    git -c user.email=t@t -c user.name=t merge --no-verify -q "$name" --no-ff -m "merge $name"
  )
}

@test "preview mode (no --yes, no --dry-run) → mode:preview, no deletions" {
  plant_merged feat/done
  out=$(bash "$SCRIPT" --target "$REPO" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.mode')" = "preview" ]
  [ "$(echo "$out" | jq -r '.summary.candidates_count')" = "1" ]
  [ "$(echo "$out" | jq -r '.summary.deleted_count')" = "0" ]
  # Branch must still exist post-preview.
  git -C "$REPO" show-ref --verify --quiet refs/heads/feat/done
}

@test "preview mode emits warn pointing at --yes recovery" {
  plant_merged feat/done
  err_file="$TMP/err.txt"
  bash "$SCRIPT" --target "$REPO" >/dev/null 2>"$err_file"
  grep -Fq -- "--yes" "$err_file"
}

@test "--dry-run → mode:dry-run, no deletions, no warn" {
  plant_merged feat/done
  err_file="$TMP/err.txt"
  out=$(bash "$SCRIPT" --target "$REPO" --dry-run 2>"$err_file")
  [ "$(echo "$out" | jq -r '.mode')" = "dry-run" ]
  [ "$(echo "$out" | jq -r '.summary.deleted_count')" = "0" ]
  git -C "$REPO" show-ref --verify --quiet refs/heads/feat/done
  ! grep -Fq -- "--yes" "$err_file"
}

@test "--yes → mode:applied, branches deleted" {
  plant_merged feat/done
  plant_merged feat/also-done
  out=$(bash "$SCRIPT" --target "$REPO" --yes 2>/dev/null)
  [ "$(echo "$out" | jq -r '.mode')" = "applied" ]
  [ "$(echo "$out" | jq -r '.summary.candidates_count')" = "2" ]
  [ "$(echo "$out" | jq -r '.summary.deleted_count')" = "2" ]
  [ "$(echo "$out" | jq -r '.summary.error_count')" = "0" ]
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/done
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/also-done
}

@test "--yes never deletes the current branch" {
  # Switch to a feature branch, merge into main while still on the
  # feature branch's lineage (no), simpler: just stay on feature
  # branch when invoking. Cleanup must leave it alone even though
  # it's checked-out.
  plant_merged feat/done
  ( cd "$REPO" && git checkout -q -b feat/keepme )
  out=$(bash "$SCRIPT" --target "$REPO" --yes 2>/dev/null)
  # feat/done was a candidate and got deleted; feat/keepme was the
  # current branch and is excluded by check-stale-branches.
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/done
  git -C "$REPO" show-ref --verify --quiet refs/heads/feat/keepme
}

@test "no merged branches → candidates_count 0, no warn" {
  err_file="$TMP/err.txt"
  out=$(bash "$SCRIPT" --target "$REPO" 2>"$err_file")
  [ "$(echo "$out" | jq -r '.summary.candidates_count')" = "0" ]
  # Warn fires only when there are candidates to delete.
  ! grep -Fq -- "--yes" "$err_file"
}

@test "non-git directory → dies" {
  notrepo="$TMP/not-a-repo"
  mkdir -p "$notrepo"
  run bash "$SCRIPT" --target "$notrepo" --yes
  [ "$status" -ne 0 ]
}

@test "--yes from a non-base branch deletes correctly (re-verified ancestry + force-delete)" {
  # `git branch -d` only checks reachability from HEAD/upstream — running
  # cleanup from a feature branch would refuse to delete branches that
  # are merged into main. This regression locks the inline ancestry
  # re-check + force-delete path: candidates merged into main MUST be
  # deleted regardless of which branch the caller has checked out.
  plant_merged feat/done-1
  plant_merged feat/done-2
  # Switch the caller onto a feature branch (NOT main).
  ( cd "$REPO" && git checkout -q -b feat/elsewhere )
  out=$(bash "$SCRIPT" --target "$REPO" --yes 2>/dev/null)
  [ "$(echo "$out" | jq -r '.summary.candidates_count')" = "2" ]
  [ "$(echo "$out" | jq -r '.summary.deleted_count')" = "2" ]
  [ "$(echo "$out" | jq -r '.summary.error_count')" = "0" ]
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/done-1
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/done-2
}

@test "output validates against cleanup-branches-result schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  plant_merged feat/done
  out_file="$TMP/result.json"
  bash "$SCRIPT" --target "$REPO" --yes > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/cleanup-branches-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/cleanup-branches-result.schema.json" "$out_file"
  fi
}
