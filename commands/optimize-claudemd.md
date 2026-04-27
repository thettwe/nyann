---
name: nyann:optimize-claudemd
description: >
  Analyze CLAUDE.md usage patterns and optimize content based on actual
  reference frequency. Removes unused sections, compresses low-density
  content, and adds frequently-used commands that are missing.
arguments:
  - name: force
    description: Skip the 10-session minimum data requirement.
    optional: true
  - name: dry-run
    description: Preview changes without writing.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:optimize-claudemd

Run the `optimize-claudemd` skill (see `skills/optimize-claudemd/SKILL.md`):

1. Analyze usage data from `memory/claudemd-usage.json`.
2. Compute per-section density (references / bytes).
3. Identify unused docs, missing commands, and low-value sections.
4. Preview and confirm optimizations.
5. Apply changes within nyann markers only.

Exit codes:
- `0` — optimization complete (or insufficient data)
- `1` — error (no tracking data, no markers, etc.)

See also:
- `/nyann:doctor` — audit repo health including CLAUDE.md size
- `/nyann:bootstrap` — initial CLAUDE.md generation with tracking opt-in
- `/nyann:explain-state` — view current CLAUDE.md contents
