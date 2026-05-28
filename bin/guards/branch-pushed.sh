#!/usr/bin/env bash
# Guard: current branch tracks a remote AND local HEAD matches remote.
# Used for PR/ship flows where the PR needs the latest commits on origin.
target="${1-$PWD}"
cd "$target" || exit 1
branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [[ -z "$branch" ]]; then
  jq -n --arg name "branch-pushed" '{name:$name,pass:false,severity:"advisory",message:"detached HEAD — push a branch first"}'
  exit 0
fi
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || echo "")
if [[ -z "$upstream" ]]; then
  jq -n --arg name "branch-pushed" --arg b "$branch" \
    '{name:$name,pass:false,severity:"advisory",message:"\($b) has no upstream — push with `git push -u origin \($b)`"}'
  exit 0
fi
local_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
remote_sha=$(git rev-parse "$upstream" 2>/dev/null || echo "")
if [[ "$local_sha" == "$remote_sha" ]]; then
  jq -n --arg name "branch-pushed" '{name:$name,pass:true,severity:"advisory",message:"in sync with upstream"}'
else
  jq -n --arg name "branch-pushed" --arg b "$branch" --arg u "$upstream" \
    '{name:$name,pass:false,severity:"advisory",message:"\($b) ahead/behind \($u) — `git push` first"}'
fi
