#!/usr/bin/env bash
# Guard: staged diff contains no unresolved merge conflict markers.
target="${1-$PWD}"
# `git diff --cached` already shows staged contents. Match git's actual
# conflict-marker form: `<<<<<<< <label>` / `>>>>>>> <label>` carry a trailing
# space before the label, and a bare `=======` separator. A bare `=======`
# alone is ambiguous (RST underlines, doc banners, changelogs) so we only count
# separators when a real `<<<<<<< ` start marker is also present — that
# combination is the unambiguous signal of an unresolved conflict.
diff=$( cd "$target" && git diff --cached --no-color 2>/dev/null )
starts=$( printf '%s\n' "$diff" | grep -cE '^\+<<<<<<< ' )
ends=$( printf '%s\n' "$diff" | grep -cE '^\+>>>>>>> ' )
if (( starts > 0 )); then
  seps=$( printf '%s\n' "$diff" | grep -cE '^\+=======$' )
else
  seps=0
fi
hits=$(( starts + seps + ends ))
if (( hits == 0 )); then
  jq -n --arg name "merge-conflict-markers" '{name:$name,pass:true,severity:"critical",message:"clean"}'
else
  jq -n --arg name "merge-conflict-markers" --argjson n "$hits" \
    '{name:$name,pass:false,severity:"critical",message:"\($n) conflict marker line(s) in staged diff"}'
fi
