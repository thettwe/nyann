#!/usr/bin/env bats
# bin/undo.sh — preview, soft/mixed/hard, refusal paths.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  UNDO="${REPO_ROOT}/bin/undo.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_feature_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
    git checkout -q -b feat/x
    echo "a" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat: add a"
    echo "b" > b.txt
    git -c user.email=t@t -c user.name=t add b.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat: add b"
  )
  echo "$repo"
}

@test "refuses outside a git repo" {
  run bash "$UNDO" --target "$TMP"
  [ "$status" -ne 0 ]
}

@test "refuses on main" {
  repo=$(make_feature_repo)
  ( cd "$repo" && git checkout -q main )
  out=$(bash "$UNDO" --target "$repo" 2>/dev/null || true)
  [ "$(echo "$out" | jq -r '.status')" = "refused" ]
  echo "$out" | jq -r '.refused_reason' | grep -F -e "long-lived"
}

@test "dry-run preview lists commits newest-first without mutating" {
  repo=$(make_feature_repo)
  before=$(git -C "$repo" rev-parse HEAD)
  out=$(bash "$UNDO" --target "$repo" --dry-run 2>/dev/null)
  after=$(git -C "$repo" rev-parse HEAD)
  [ "$before" = "$after" ]
  [ "$(echo "$out" | jq -r '.status')" = "preview" ]
  [ "$(echo "$out" | jq -r '.undone_commits[0].subject')" = "feat: add b" ]
  [ "$(echo "$out" | jq '.count')" -eq 1 ]
}

@test "soft strategy (default) keeps changes staged" {
  repo=$(make_feature_repo)
  out=$(bash "$UNDO" --target "$repo" --yes 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "undone" ]
  [ "$(echo "$out" | jq -r '.strategy')" = "soft" ]
  # Post-state: b.txt is staged.
  git -C "$repo" diff --cached --name-only | grep -F -e "b.txt"
}

@test "mixed strategy unstages changes" {
  repo=$(make_feature_repo)
  out=$(bash "$UNDO" --target "$repo" --yes --strategy mixed 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "undone" ]
  # Post-state: b.txt is modified but not staged.
  [ "$(git -C "$repo" diff --cached --name-only | wc -l | tr -d ' ')" = "0" ]
  git -C "$repo" status --porcelain | grep -F -e "b.txt"
}

@test "hard strategy discards changes" {
  repo=$(make_feature_repo)
  out=$(bash "$UNDO" --target "$repo" --yes --strategy hard 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "undone" ]
  [ ! -f "$repo/b.txt" ]
  # Tree is clean.
  [ -z "$(git -C "$repo" status --porcelain)" ]
}

@test "last-N-commits with --count 2 undoes 2 commits" {
  repo=$(make_feature_repo)
  out=$(bash "$UNDO" --target "$repo" --yes --scope last-N-commits --count 2 --strategy hard 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "undone" ]
  [ "$(echo "$out" | jq '.count')" -eq 2 ]
  [ "$(echo "$out" | jq '.undone_commits | length')" -eq 2 ]
  # HEAD should now be the seed.
  [ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" = "1" ]
}

@test "refuses when --count exceeds available commits" {
  repo=$(make_feature_repo)
  out=$(bash "$UNDO" --target "$repo" --scope last-N-commits --count 99 2>/dev/null || true)
  [ "$(echo "$out" | jq -r '.status')" = "refused" ]
  echo "$out" | jq -r '.refused_reason' | grep -F -e "fewer than 99"
}

@test "refuses to undo a merge commit" {
  local repo="$TMP/merge"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: root"
    git checkout -q -b feat/x
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: x"
    git checkout -q main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: on main"
    git checkout -q -b feat/y
    git -c user.email=t@t -c user.name=t -c merge.autoStash=false merge --no-ff --no-edit feat/x >/dev/null
  )
  out=$(bash "$UNDO" --target "$repo" 2>/dev/null || true)
  [ "$(echo "$out" | jq -r '.status')" = "refused" ]
  echo "$out" | jq -r '.refused_reason' | grep -F -e "merge commit"
}

@test "invalid --strategy dies" {
  repo=$(make_feature_repo)
  run bash "$UNDO" --target "$repo" --strategy superhard
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "soft|mixed|hard"
}

@test "invalid --count (zero) dies" {
  repo=$(make_feature_repo)
  run bash "$UNDO" --target "$repo" --scope last-N-commits --count 0
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "positive integer"
}

# ---- preview-before-mutate guard ------------------------------------------
# undo's header docstring promises "Always emits a JSON preview first.
# Mutation happens only when --dry-run is NOT set AND preview has been
# emitted." Without --yes the script must emit the preview and exit
# without running git reset. This is the same preview/confirm shape as
# bin/switch-profile.sh — direct-shell callers can't bypass the
# consent gate that the skill layer enforces.

@test "without --yes the script emits preview and refuses to mutate" {
  repo=$(make_feature_repo)
  before=$(git -C "$repo" rev-parse HEAD)
  out=$(bash "$UNDO" --target "$repo" 2>/dev/null)
  after=$(git -C "$repo" rev-parse HEAD)
  # The reset MUST NOT have happened.
  [ "$before" = "$after" ]
  # Status should be "preview" (not "undone").
  [ "$(echo "$out" | jq -r '.status')" = "preview" ]
  # The b.txt file (last commit) must still be in the tree.
  [ -f "$repo/b.txt" ]
}

@test "with --yes the script applies the reset" {
  repo=$(make_feature_repo)
  before=$(git -C "$repo" rev-parse HEAD)
  out=$(bash "$UNDO" --target "$repo" --yes --strategy hard 2>/dev/null)
  after=$(git -C "$repo" rev-parse HEAD)
  [ "$before" != "$after" ]
  [ "$(echo "$out" | jq -r '.status')" = "undone" ]
}
