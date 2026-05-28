#!/usr/bin/env bash
# Guard: commits between the branch and its base contain no WIP markers.
# "WIP" sneaking into a PR is a top-3 commit-review complaint.
target="${1-$PWD}"
base="${2:-main}"
cd "$target" || exit 1
# If base doesn't exist, soft-skip.
if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
  jq -n --arg name "wip-commits" '{name:$name,pass:true,severity:"advisory",skipped:true,message:"base branch not found — skipped"}'
  exit 0
fi
hits=$(git log "${base}..HEAD" --pretty=format:'%s' 2>/dev/null \
  | grep -iE '^(wip|fixup!|squash!)\b|\[wip\]|\bWIP\b' \
  | wc -l | tr -d ' ')
if (( hits == 0 )); then
  jq -n --arg name "wip-commits" '{name:$name,pass:true,severity:"advisory",message:"no WIP commits"}'
else
  jq -n --arg name "wip-commits" --argjson n "$hits" \
    '{name:$name,pass:false,severity:"advisory",message:"\($n) WIP/fixup/squash commit(s) — rebase before opening PR"}'
fi
