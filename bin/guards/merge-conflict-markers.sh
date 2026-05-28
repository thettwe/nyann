#!/usr/bin/env bash
# Guard: staged diff contains no unresolved merge conflict markers.
target="${1-$PWD}"
# `git diff --cached` already shows staged contents. Filter for marker lines
# only in added lines (prefix `+`) to avoid matching markers that already
# existed verbatim (rare, but possible — markdown examples of conflicts).
hits=$( cd "$target" && git diff --cached --no-color 2>/dev/null \
  | grep -E '^\+(<<<<<<<|=======$|>>>>>>>)' \
  | wc -l | tr -d ' ' )
if (( hits == 0 )); then
  jq -n --arg name "merge-conflict-markers" '{name:$name,pass:true,severity:"critical",message:"clean"}'
else
  jq -n --arg name "merge-conflict-markers" --argjson n "$hits" \
    '{name:$name,pass:false,severity:"critical",message:"\($n) conflict marker line(s) in staged diff"}'
fi
