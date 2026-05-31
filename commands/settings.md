---
name: nyann:settings
description: >
  Interactive settings menu for nyann preferences. Pick one setting,
  change its value, see the updated table, then pick another or done.
arguments:
  - name: key
    description: Optional direct-edit key (e.g., session_triage). When passed with a value, skips the menu and writes immediately.
    optional: true
  - name: value
    description: Optional direct-edit value (e.g., false). Used only when `key` is also given.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/settings/SKILL.md` for the full flow.


# /nyann:settings

Wraps `bin/settings.sh`. Interactive menu over the eleven preferences
managed in `~/.claude/nyann/preferences.json`.

- No arguments → show the current table, then ask "Which setting to
  change?" via `AskUserQuestion`.
- `<key> <value>` (two positional args) → bypass the menu and run
  `bin/settings.sh --set <key> <value>` directly.

Use for ongoing preference management. Use `/nyann:setup` only for
first-run onboarding.
