#!/usr/bin/env bash
# Guard: at least one file is staged. Critical for commit flow — there's
# nothing to commit otherwise.
target="${1-$PWD}"
staged=$( cd "$target" && git diff --cached --name-only 2>/dev/null | grep -c '.' || true )
if (( staged > 0 )); then
  jq -n --arg name "staged-files-exist" '{name:$name,pass:true,severity:"critical",message:"\($name) ok"}'
else
  jq -n --arg name "staged-files-exist" '{name:$name,pass:false,severity:"critical",message:"no files staged — `git add` something first"}'
fi
