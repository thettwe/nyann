---
name: nyann:pr
description: >
  Open a GitHub pull request from the current branch. Pushes with `-u`
  tracking, then invokes `gh pr create`. Requires `gh` installed + authed.
arguments:
  - name: draft
    description: If passed, open the PR as a draft.
    optional: true
  - name: base
    description: Target base branch. Defaults to upstream / origin HEAD / `main`.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:pr

Wraps `bin/pr.sh`. Full flow:

1. `bin/pr.sh --context-only` to gather branch + commit range + suggested title.
2. Synthesize a Conventional-Commits title + markdown body from the commit list.
3. Show the user and ask to ship (skip ask if they said "just ship it").
4. `bin/pr.sh --title "..." --body "..." [--base <b>] [--draft]` to push + create.
5. Report the URL.

See `skills/pr/SKILL.md` for natural-language trigger rules and error-handling.
