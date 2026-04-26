---
name: nyann:setup
description: >
  First-run onboarding for nyann. Collects user preferences and creates
  the ~/.claude/nyann/ config structure. Re-runnable to update preferences.
---

# /nyann:setup

Run the onboarding flow defined in `skills/setup/SKILL.md`:

1. Check current status via `bin/setup.sh --check --json`.
2. If already configured, show current preferences and offer to update.
3. If not configured, run prerequisites check (`bin/check-prereqs.sh`),
   then collect preferences interactively (see SKILL.md §3 for each
   question).
4. Write preferences via `bin/setup.sh` with the collected flags.
5. Suggest next steps: `/nyann:bootstrap`, `/nyann:check-prereqs`,
   `/nyann:add-team-source`.

**This skill configures nyann itself, not a repo.** For repo setup, use
`/nyann:bootstrap`.

See also:
- `/nyann:bootstrap` — set up a project with a profile.
- `/nyann:check-prereqs` — survey machine tools (read-only).
- `/nyann:add-team-source` — register a team profile repo.
