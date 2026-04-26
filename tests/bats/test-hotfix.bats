#!/usr/bin/env bats
# bin/hotfix.sh — sets up release/<m>.<n> + hotfix/<slug> branches
# off a previously tagged version.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/bin/hotfix.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: v1" \
    && git tag v1.2.3 \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: post-v1 work" )
}

teardown() { rm -rf "$TMP"; }

@test "happy path: creates release/1.2 + hotfix/<slug>, suggests patch version" {
  out=$(bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x 2>/dev/null)
  [ "$(echo "$out" | jq -r '.release_branch')"          = "release/1.2" ]
  [ "$(echo "$out" | jq -r '.hotfix_branch')"           = "hotfix/fix-x" ]
  [ "$(echo "$out" | jq -r '.release_branch_created')"  = "true" ]
  [ "$(echo "$out" | jq -r '.hotfix_branch_created')"   = "true" ]
  # Both branches exist locally now.
  git -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2
  git -C "$REPO" show-ref --verify --quiet refs/heads/hotfix/fix-x
  # release/1.2 points at v1.2.3, not at the post-v1 work.
  [ "$(git -C "$REPO" rev-parse refs/heads/release/1.2)" = "$(git -C "$REPO" rev-parse v1.2.3)" ]
  # next_steps suggests the patch bump (1.2.4).
  echo "$out" | jq -e '[.next_steps[] | select(test("--version 1.2.4"))] | length >= 1' >/dev/null
  # next_steps must NOT include the invalid `--base` flag (release.sh
  # doesn't accept it; the fixed flow uses checkout + merge instead).
  echo "$out" | jq -e '[.next_steps[] | select(test("--base"))] | length == 0' >/dev/null
  # And the merge-into-release step is present.
  echo "$out" | jq -e '[.next_steps[] | select(test("git checkout " + "release/1.2"))] | length >= 1' >/dev/null
  echo "$out" | jq -e '[.next_steps[] | select(test("git merge --no-ff " + "hotfix/fix-x"))] | length >= 1' >/dev/null
}

@test "second invocation reuses an existing release branch (idempotent)" {
  bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x >/dev/null 2>/dev/null
  # Now run with a different slug; release/1.2 already exists at v1.2.3.
  out=$(bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-y 2>/dev/null)
  [ "$(echo "$out" | jq -r '.release_branch_created')" = "false" ]
  [ "$(echo "$out" | jq -r '.hotfix_branch_created')"  = "true" ]
  git -C "$REPO" show-ref --verify --quiet refs/heads/hotfix/fix-y
}

@test "release branch tip != source tag → refuses (no silent rebasing onto stale work)" {
  # First hotfix off v1.2.3 lands; user advances release/1.2 with a
  # new commit (simulating a tagged v1.2.4 having been merged in).
  # Second hotfix call also asks --from v1.2.3 — but the branch is
  # past it now. Refuse instead of silently forking from v1.2.4.
  bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x >/dev/null 2>/dev/null
  ( cd "$REPO" \
      && git checkout -q release/1.2 \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: extra commit"
  )
  run bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-y
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "tip is at"
  echo "$output" | grep -F -e "Hotfix would either skip commits or include unrelated work"
  # New hotfix branch must NOT have been created.
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/hotfix/fix-y
}

@test "existing hotfix branch → refuses (no silent overwrite)" {
  bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x >/dev/null 2>/dev/null
  run bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "already exists locally"
}

@test "missing tag → refuses with explicit error" {
  run bash "$SCRIPT" --target "$REPO" --from v9.9.9 --slug fix-x
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "not found locally"
}

@test "non-semver tag without --release-branch override → refuses" {
  ( cd "$REPO" && git tag random-tag-name )
  run bash "$SCRIPT" --target "$REPO" --from random-tag-name --slug fix-x
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--release-branch"
}

@test "non-semver tag WITH --release-branch override → succeeds" {
  ( cd "$REPO" && git tag custom-cut )
  out=$(bash "$SCRIPT" --target "$REPO" --from custom-cut --slug fix-x \
    --release-branch release/custom 2>/dev/null)
  [ "$(echo "$out" | jq -r '.release_branch')" = "release/custom" ]
  git -C "$REPO" show-ref --verify --quiet refs/heads/release/custom
}

@test "invalid slug shape → refuses" {
  run bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug "Bad Slug"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "lowercase"
}

@test "--checkout switches to the hotfix branch" {
  bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x --checkout >/dev/null 2>/dev/null
  current=$(git -C "$REPO" symbolic-ref --short HEAD)
  [ "$current" = "hotfix/fix-x" ]
}

@test "non-git directory → dies" {
  notrepo="$TMP/not-a-repo"
  mkdir -p "$notrepo"
  run bash "$SCRIPT" --target "$notrepo" --from v1.2.3 --slug fix-x
  [ "$status" -ne 0 ]
}

@test "missing --from → dies" {
  run bash "$SCRIPT" --target "$REPO" --slug fix-x
  [ "$status" -ne 0 ]
}

@test "missing --slug → dies" {
  run bash "$SCRIPT" --target "$REPO" --from v1.2.3
  [ "$status" -ne 0 ]
}

@test "output validates against hotfix-result schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  out_file="$TMP/result.json"
  bash "$SCRIPT" --target "$REPO" --from v1.2.3 --slug fix-x > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/hotfix-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/hotfix-result.schema.json" "$out_file"
  fi
}
