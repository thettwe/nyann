---
name: nyann:setup
description: >
  First-run onboarding for nyann. Collects user preferences and creates
  the ~/.claude/nyann/ config structure. Re-runnable to update preferences.
---

# /nyann:setup

**Plugin root:** nyann is a Claude Code plugin, NOT a CLI tool. Do NOT
search for it via `which`, `npm list`, `pip list`, or `brew list`.
Determine the plugin root from this file's path — this command file is
at `<plugin_root>/commands/setup.md`, so the plugin root is its parent
directory. All scripts are at `<plugin_root>/bin/`.

Read `skills/setup/SKILL.md` (relative to the plugin root) and follow
its instructions exactly. The SKILL.md defines the complete flow
including `AskUserQuestion` interactive pickers.

**This skill configures nyann itself, not a repo.** For repo setup, use
`/nyann:bootstrap`.
