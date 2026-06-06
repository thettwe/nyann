#!/usr/bin/env bash
# Guard: working tree is clean. Required for release flow.
target="${1-$PWD}"
cd "$target" || exit 1
# If not inside a git work tree, soft-skip — a non-repo can't be "clean".
# `git status --porcelain` would emit nothing here and falsely report pass.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  jq -n --arg name "clean-tree" '{name:$name,pass:true,severity:"critical",skipped:true,message:"not a git repository — skipped"}'
  exit 0
fi
dirty=$(git status --porcelain 2>/dev/null | head -1)
if [[ -z "$dirty" ]]; then
  jq -n --arg name "clean-tree" '{name:$name,pass:true,severity:"critical",message:"clean"}'
else
  jq -n --arg name "clean-tree" '{name:$name,pass:false,severity:"critical",message:"working tree has uncommitted changes — stash or commit before release"}'
fi
