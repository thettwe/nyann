---
name: nyann:explain-state
description: >
  Print a read-only summary of what nyann sees: stack, profile, branching,
  hooks, CLAUDE.md status, recent commits.
arguments:
  - name: json
    description: Emit machine-readable JSON instead of a human-readable table.
    optional: true
  - name: profile
    description: Override profile inference — pass an explicit profile name.
    optional: true
---

# /nyann:explain-state

Wraps `bin/explain-state.sh`. Read-only. Aggregates:

- Stack detection (language, framework, package_manager, confidence)
- Inferred profile (from CLAUDE.md or `--profile`)
- Branching strategy + base branches (from profile)
- Hook signals (husky / pre-commit.com / nyann core)
- CLAUDE.md presence + size + router markers
- 5 most recent commits

Use as a first-look diagnostic before `doctor` (audit) or `bootstrap-project` (setup/retrofit).

See `skills/explain-state/SKILL.md` for what to read back to the user.
