#!/usr/bin/env bats
# bin/sync.sh — branch safety, clean-tree check, rebase/merge paths.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SYNC="${REPO_ROOT}/bin/sync.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_divergent_repo() {
  # Creates a repo where feat/x is 1 behind main (no conflicts).
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    echo "one" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "chore: one"
    git checkout -q -b feat/x
    echo "b" > b.txt
    git -c user.email=t@t -c user.name=t add b.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat: add b"
    # Now put a new commit on main so feat/x is behind.
    git checkout -q main
    echo "two" >> a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "chore: two"
    git checkout -q feat/x
  )
  echo "$repo"
}

make_conflict_repo() {
  # Same file edited on both branches — rebase will conflict.
  local repo="$TMP/repo-c"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    echo "one" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "chore: one"
    git checkout -q -b feat/x
    echo "FEATURE" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat: edit a"
    git checkout -q main
    echo "MAIN" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "chore: edit a"
    git checkout -q feat/x
  )
  echo "$repo"
}

@test "refuses on main (exit 2)" {
  repo=$(make_divergent_repo)
  ( cd "$repo" && git checkout -q main )
  run bash "$SYNC" --target "$repo"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "refusing to sync main"
}

@test "refuses outside a git repo (exit 2)" {
  run bash "$SYNC" --target "$TMP"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "not a git repo"
}

@test "refuses with a dirty working tree (status=dirty, exit 1)" {
  repo=$(make_divergent_repo)
  echo "uncommitted" > "$repo/dirty.txt"
  ( cd "$repo" && git -c user.email=t@t -c user.name=t add dirty.txt )  # staged but not committed
  out=$(bash "$SYNC" --target "$repo" 2>/dev/null || true)
  [ "$(echo "$out" | jq -r '.status')" = "dirty" ]
}

@test "rebase path: up-to-date when behind==0" {
  repo=$(make_divergent_repo)
  # feat/x is behind main — first sync once to make it up-to-date.
  bash "$SYNC" --target "$repo" >/dev/null 2>&1
  out=$(bash "$SYNC" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')"   = "up-to-date" ]
  [ "$(echo "$out" | jq -r '.strategy')" = "rebase" ]
}

@test "rebase path: synced when behind>0 and no conflicts" {
  repo=$(make_divergent_repo)
  out=$(bash "$SYNC" --target "$repo" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')"   = "synced" ]
  [ "$(echo "$out" | jq -r '.strategy')" = "rebase" ]
  [ "$(echo "$out" | jq -r '.head')"     = "feat/x" ]
  [ "$(echo "$out" | jq -r '.base')"     = "main" ]
}

@test "rebase path: reports conflicts and leaves rebase in progress" {
  repo=$(make_conflict_repo)
  out=$(bash "$SYNC" --target "$repo" 2>/dev/null || true)
  [ "$(echo "$out" | jq -r '.status')" = "conflicts" ]
  [ "$(echo "$out" | jq '.conflicts | length')" -gt 0 ]
  # Clean up the half-rebased repo.
  ( cd "$repo" && git rebase --abort 2>/dev/null ) || true
}

@test "merge strategy: synced when behind>0 and no conflicts" {
  repo=$(make_divergent_repo)
  out=$(bash "$SYNC" --target "$repo" --strategy merge 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')"   = "synced" ]
  [ "$(echo "$out" | jq -r '.strategy')" = "merge" ]
}

@test "--dry-run on a behind branch reports synced without mutating" {
  repo=$(make_divergent_repo)
  before=$(git -C "$repo" rev-parse HEAD)
  out=$(bash "$SYNC" --target "$repo" --dry-run 2>/dev/null)
  after=$(git -C "$repo" rev-parse HEAD)
  [ "$(echo "$out" | jq -r '.status')" = "synced" ]
  [ "$before" = "$after" ]
}

@test "invalid --strategy value dies" {
  repo=$(make_divergent_repo)
  run bash "$SYNC" --target "$repo" --strategy cherry-pick
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--strategy must be rebase or merge"
}
