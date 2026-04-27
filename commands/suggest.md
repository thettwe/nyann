---
name: nyann:suggest
description: >
  Analyze a repository and suggest profile updates based on installed
  dependencies, config files, repo structure, and git history patterns.
arguments:
  - name: profile
    description: Profile name to analyze against. If omitted, resolves from preferences or CLAUDE.md markers.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:suggest

Run the `suggest` skill (see `skills/suggest/SKILL.md`):

1. Detect the stack with `bin/detect-stack.sh`.
2. Resolve the active profile (argument → preferences → CLAUDE.md → default).
3. Run `bin/suggest-profile-updates.sh` to find gaps.
4. Present grouped suggestions with confidence scores.
5. Offer to apply selected suggestions to the profile.

Exit codes:
- `0` — analysis complete (may have 0 suggestions)
- `1` — error (invalid profile, missing target, etc.)

See also:
- `/nyann:inspect-profile` — view current profile contents
- `/nyann:migrate-profile` — switch between profiles
- `/nyann:doctor` — audit overall repo health
