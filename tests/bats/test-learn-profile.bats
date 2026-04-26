#!/usr/bin/env bats
# bin/learn-profile.sh against the jsts-bootstrapped fixture + synthetic cases.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LEARN="${REPO_ROOT}/bin/learn-profile.sh"
  TMP="$(mktemp -d)"
  UR="$TMP/user-root"
  mkdir -p "$UR/profiles"
}

teardown() { rm -rf "$TMP"; }

seed_jsts_bootstrapped() {
  cp -r "${REPO_ROOT}/tests/fixtures/jsts-bootstrapped/." "$TMP/src/"
  ( cd "$TMP/src" && ./seed.sh >/dev/null 2>&1 )
}

@test "jsts-bootstrapped → learned profile has TypeScript + next + pnpm stack" {
  seed_jsts_bootstrapped
  run bash "$LEARN" --target "$TMP/src" --name learned --user-root "$UR"
  [ "$status" -eq 0 ]
  p="$UR/profiles/learned.json"
  [ -f "$p" ]
  [ "$(jq -r '.stack.primary_language' "$p")" = "typescript" ]
  [ "$(jq -r '.stack.framework'        "$p")" = "next" ]
  [ "$(jq -r '.stack.package_manager'  "$p")" = "pnpm" ]
}

@test "jsts-bootstrapped → learned profile includes commit_msg conventional-commits" {
  seed_jsts_bootstrapped
  bash "$LEARN" --target "$TMP/src" --name learned --user-root "$UR" >/dev/null 2>&1
  jq -e '.hooks.commit_msg | contains(["conventional-commits"])' "$UR/profiles/learned.json" >/dev/null
}

@test "mixed-format history → commit_format = unknown" {
  d="$TMP/mixed"
  mkdir -p "$d"
  ( cd "$d" && git init -q -b main
    for m in "feat: one" "random" "fix: two" "junk" "whatever"; do
      git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$m"
    done )
  bash "$LEARN" --target "$d" --name mixed --user-root "$UR" >/dev/null 2>&1
  [ "$(jq -r '.conventions.commit_format' "$UR/profiles/mixed.json")" = "unknown" ]
}

@test "develop + semver tag → branching.strategy = gitflow" {
  d="$TMP/gf"
  mkdir -p "$d"
  ( cd "$d" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" \
    && git branch develop && git tag v1.0.0 )
  bash "$LEARN" --target "$d" --name gf --user-root "$UR" >/dev/null 2>&1
  [ "$(jq -r '.branching.strategy' "$UR/profiles/gf.json")" = "gitflow" ]
}

@test "assembled profile passes bin/validate-profile.sh" {
  seed_jsts_bootstrapped
  bash "$LEARN" --target "$TMP/src" --name learned --user-root "$UR" >/dev/null 2>&1
  run bash "${REPO_ROOT}/bin/validate-profile.sh" "$UR/profiles/learned.json"
  [ "$status" -eq 0 ]
}

@test "repo with .github/workflows → learned profile sets ci.enabled=true (and the legacy extras flag)" {
  # Consumers (bootstrap.sh, switch-profile.sh) gate CI generation on
  # .ci.enabled. Setting only extras.github_actions_ci silently drops
  # CI on apply.
  d="$TMP/with-ci"
  mkdir -p "$d/.github/workflows"
  echo "name: ci" > "$d/.github/workflows/ci.yml"
  ( cd "$d" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: seed" )
  bash "$LEARN" --target "$d" --name with-ci --user-root "$UR" >/dev/null 2>&1
  p="$UR/profiles/with-ci.json"
  [ "$(jq -r '.ci.enabled'              "$p")" = "true" ]
  [ "$(jq -r '.extras.github_actions_ci' "$p")" = "true" ]
}

@test "repo without .github/workflows → ci.enabled=false (and no false-positive extras flag)" {
  d="$TMP/no-ci"
  mkdir -p "$d"
  ( cd "$d" && git init -q -b main \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: seed" )
  bash "$LEARN" --target "$d" --name no-ci --user-root "$UR" >/dev/null 2>&1
  p="$UR/profiles/no-ci.json"
  [ "$(jq -r '.ci.enabled' "$p")" = "false" ]
  [ "$(jq -r '.extras.github_actions_ci // false' "$p")" = "false" ]
}

@test "missing .pre-commit-config.yaml tolerated (no crash, empty hooks slot)" {
  d="$TMP/no-pre-commit"
  mkdir -p "$d"
  ( cd "$d" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
  run bash "$LEARN" --target "$d" --name noprc --user-root "$UR"
  [ "$status" -eq 0 ]
  # hooks.pre_commit may be empty; the key must still exist with an array.
  [ "$(jq -r '.hooks.pre_commit | type' "$UR/profiles/noprc.json")" = "array" ]
}

@test "inspect-profile renders every section" {
  INSPECT="${REPO_ROOT}/bin/inspect-profile.sh"
  run bash "$INSPECT" nextjs-prototype
  [ "$status" -eq 0 ]
  for section in "Stack:" "Branching:" "Hooks:" "Extras:" "Conventions:" "Documentation:"; do
    echo "$output" | grep -Fq "$section"
  done
}

@test "inspect-profile on missing profile → exit 2 with available list" {
  INSPECT="${REPO_ROOT}/bin/inspect-profile.sh"
  run bash "$INSPECT" does-not-exist --user-root /tmp/nyann-empty-$$
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "profile not found"
}
