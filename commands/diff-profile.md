---
name: nyann:diff-profile
description: >
  Compare two nyann profiles side-by-side and show what changes between them:
  hooks, branching, CI, documentation, extras, governance. Useful before
  switching profiles to understand the impact.
arguments:
  - name: from
    description: The source profile name (e.g. "default", "python-cli").
    optional: false
  - name: to
    description: The target profile name to compare against.
    optional: false
  - name: format
    description: Output format — "human" for readable text, "json" for structured output. Defaults to human.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:diff-profile

Wraps `bin/diff-profile.sh <from> <to> [--format human|json]`.

Shows a structured diff between two profiles, organized by section:

```
Stack:
  primary_language: unknown → typescript
  framework: null → next

Hooks:
  [pre_commit]
    + lint-staged, eslint, prettier
  [commit_msg]
    (no changes)

Documentation:
  scaffold_types: ["architecture","adrs"] → ["architecture","adrs","prd"]
  claude_md_size_budget_kb: 3 → 5
```

Both arguments are bare profile names resolved via `bin/load-profile.sh`.
User, team, and starter profiles are all supported.

## When to invoke

- "What's different between default and python-cli?" → run this.
- "What would change if I switch profiles?" → resolve current profile
  from CLAUDE.md, then diff current vs target.
- "Compare these two profiles" → run this.

## See also

- `/nyann:inspect-profile` — inspect a single profile in detail.
- `/nyann:migrate-profile` — actually switch from one profile to another.
- `/nyann:retrofit` — apply profile changes to the repo.
