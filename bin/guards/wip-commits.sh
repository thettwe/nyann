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
# Match WIP markers only at the START of the subject line (or as the
# literal `[wip]` bracket form). The previous `\bWIP\b` arm fired on
# any subject containing the word WIP as a topic (e.g.
# `feat: improve wip management`), which produces too many false
# positives to be useful. A commit that's actually WIP almost always
# leads with `wip:`, `WIP:`, `fixup!`, or `squash!`.
hits=$(git log "${base}..HEAD" --pretty=format:'%s' 2>/dev/null \
  | grep -iE '^(wip[[:space:]:!]|fixup![[:space:]]|squash![[:space:]])|\[wip\]' \
  | wc -l | tr -d ' ')
if (( hits == 0 )); then
  jq -n --arg name "wip-commits" '{name:$name,pass:true,severity:"advisory",message:"no WIP commits"}'
else
  jq -n --arg name "wip-commits" --argjson n "$hits" \
    '{name:$name,pass:false,severity:"advisory",message:"\($n) WIP/fixup/squash commit(s) — rebase before opening PR"}'
fi
