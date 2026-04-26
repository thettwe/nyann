---
name: migrate-profile
description: "Switch this repository from one nyann profile to another. TRIGGER ON: 'switch profile', 'migrate profile', 'change this repo profile', 'switch from X to Y', 'change profile to', 'migrate from', 'use a different profile', 'switch to nextjs', 'switch to python'. Computes a diff between source and target profiles, previews all hook/config/convention changes, and applies via bootstrap."
---

# migrate-profile — Switch Between Nyann Profiles

You are the migrate-profile skill. You switch a repository from one nyann profile to another, computing the diff and applying changes safely.

## When to trigger

- User asks to switch, migrate, or change the repo's profile
- User says "switch from X to Y" or "use the python profile instead"
- User asks to change the repo's configuration to match a different stack

**DO NOT trigger on:** schema version migration (that's `bin/migrate-profile.sh`), initial bootstrap, or retrofit.

## Execution flow

### Phase 1: Identify source and target profiles

1. **Source profile**: resolve from CLAUDE.md markers or preferences. If ambiguous, ask.
2. **Target profile**: from the user's request. If they named a profile, use it. If they described a stack ("switch to Python"), resolve to the matching starter profile.
3. Validate both exist via `bin/load-profile.sh <name>` (positional argument).

### Phase 2: Compute and preview diff

4. Run `bin/switch-profile.sh --from <source> --to <target> --target . --dry-run`.
5. Show a human-readable table of changes:
   - Hooks added/removed per phase
   - Branching strategy change
   - Extras toggled
   - Convention changes
   - CI configuration changes
6. Highlight potentially destructive changes (hook removals, strategy changes).

### Phase 3: Confirm and apply

7. Ask: "Apply this migration? This will regenerate CLAUDE.md and update hooks."
8. On confirmation, re-run with `--yes` (and without `--dry-run`).
   The script refuses to apply without `--yes`; emitting the plan and
   asking is the human-confirm half of preview-before-mutate.
9. Report what changed.

### Phase 4: Post-migration

10. Suggest running `/nyann:doctor` to verify the new state.
11. Suggest committing the changes.

## Key constraints

- The script diffs two profiles — it doesn't modify the profile files themselves.
- Bootstrap is re-run with the new profile to regenerate managed files.
- User content outside nyann markers is always preserved.
- If the profiles are identical, report "nothing to migrate" and exit cleanly.

## When to hand off

- "Check if the migration worked" → `doctor` skill.
- "Regenerate CLAUDE.md" → `gen-claudemd` skill (if CLAUDE.md wasn't
  refreshed during the migration).
- "What does the new profile look like?" → `inspect-profile` skill.
- "Undo the migration" → if not yet committed, restore individual
  files with `git checkout -- <file>` for each changed file. If
  already committed, use the `undo` skill to revert the commit.
