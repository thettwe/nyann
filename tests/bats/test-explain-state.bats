#!/usr/bin/env bats
# bin/explain-state.sh — JSON summary shape + human render smoke test.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  STATE="${REPO_ROOT}/bin/explain-state.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_basic_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
  )
  echo "$repo"
}

@test "refuses non-git-repo (exit 2)" {
  run bash "$STATE" --target "$TMP"
  [ "$status" -eq 2 ]
}

@test "--json emits all six top-level blocks" {
  repo=$(make_basic_repo)
  out=$(bash "$STATE" --target "$repo" --json 2>/dev/null)
  [ "$(echo "$out" | jq -r '.repo')"                != "" ]
  [ "$(echo "$out" | jq -r '.branch')"              = "main" ]
  [ "$(echo "$out" | jq 'has("stack")')"            = "true" ]
  [ "$(echo "$out" | jq 'has("profile")')"          = "true" ]
  [ "$(echo "$out" | jq 'has("branching")')"        = "true" ]
  [ "$(echo "$out" | jq 'has("hooks")')"            = "true" ]
  [ "$(echo "$out" | jq 'has("claude_md")')"        = "true" ]
  [ "$(echo "$out" | jq 'has("recent_commits")')"   = "true" ]
}

@test "--profile override: sets profile name + source=starter when file exists" {
  repo=$(make_basic_repo)
  out=$(bash "$STATE" --target "$repo" --json --profile nextjs-prototype 2>/dev/null)
  [ "$(echo "$out" | jq -r '.profile.name')"   = "nextjs-prototype" ]
  [ "$(echo "$out" | jq -r '.profile.source')" = "starter" ]
}

@test "--profile override: unknown name → source=unknown" {
  repo=$(make_basic_repo)
  out=$(bash "$STATE" --target "$repo" --json --profile nothing-here 2>/dev/null)
  [ "$(echo "$out" | jq -r '.profile.name')"   = "nothing-here" ]
  [ "$(echo "$out" | jq -r '.profile.source')" = "unknown" ]
}

@test "claude_md: present + bytes + router markers when CLAUDE.md exists" {
  repo=$(make_basic_repo)
  printf '%s\n' '# CLAUDE.md' '<!-- nyann:start -->' 'Profile: \`nextjs-prototype\`' '<!-- nyann:end -->' > "$repo/CLAUDE.md"
  out=$(bash "$STATE" --target "$repo" --json 2>/dev/null)
  [ "$(echo "$out" | jq -r '.claude_md.present')"        = "true" ]
  [ "$(echo "$out" | jq '.claude_md.bytes')" -gt 0 ]
  [ "$(echo "$out" | jq -r '.claude_md.router_markers')" = "true" ]
}

@test "claude_md: absent when no CLAUDE.md" {
  repo=$(make_basic_repo)
  out=$(bash "$STATE" --target "$repo" --json 2>/dev/null)
  [ "$(echo "$out" | jq -r '.claude_md.present')" = "false" ]
  [ "$(echo "$out" | jq '.claude_md.bytes')"      -eq 0 ]
}

@test "hooks signals pick up husky and pre-commit.com when files exist" {
  repo=$(make_basic_repo)
  mkdir -p "$repo/.husky"
  echo "#!/bin/sh" > "$repo/.husky/pre-commit"
  touch "$repo/.pre-commit-config.yaml"
  out=$(bash "$STATE" --target "$repo" --json 2>/dev/null)
  [ "$(echo "$out" | jq -r '.hooks.husky')"           = "true" ]
  [ "$(echo "$out" | jq -r '.hooks.pre_commit_com')"  = "true" ]
}

@test "human output names each section" {
  repo=$(make_basic_repo)
  run bash "$STATE" --target "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "Stack:"
  echo "$output" | grep -F -e "Profile:"
  echo "$output" | grep -F -e "Branching:"
  echo "$output" | grep -F -e "Hooks:"
  echo "$output" | grep -F -e "CLAUDE.md:"
}

@test "recent_commits reports the last 5 or fewer" {
  repo=$(make_basic_repo)
  (
    cd "$repo"
    for i in 1 2 3; do
      echo "$i" > "$i.txt"
      git -c user.email=t@t -c user.name=t add "$i.txt"
      git -c user.email=t@t -c user.name=t commit -q -m "feat: add $i"
    done
  )
  out=$(bash "$STATE" --target "$repo" --json 2>/dev/null)
  n=$(echo "$out" | jq '.recent_commits | length')
  [ "$n" -ge 3 ]
  [ "$n" -le 5 ]
}
