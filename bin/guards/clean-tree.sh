#!/usr/bin/env bash
# Guard: working tree is clean. Required for release flow.
target="${1-$PWD}"
cd "$target" || exit 1
dirty=$(git status --porcelain 2>/dev/null | head -1)
if [[ -z "$dirty" ]]; then
  jq -n --arg name "clean-tree" '{name:$name,pass:true,severity:"critical",message:"clean"}'
else
  jq -n --arg name "clean-tree" '{name:$name,pass:false,severity:"critical",message:"working tree has uncommitted changes — stash or commit before release"}'
fi
