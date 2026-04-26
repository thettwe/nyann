---
name: nyann:migrate-profile
description: >
  Switch this repository from one nyann profile to another. Computes a
  diff between source and target profiles, shows what will change
  (hooks, branching, extras, conventions), and applies via bootstrap.
arguments:
  - name: from
    description: Source profile name. If omitted, resolves from CLAUDE.md markers or preferences.
    optional: true
  - name: to
    description: Target profile name to switch to.
    optional: false
---

# /nyann:migrate-profile

Run the `migrate-profile` skill (see `skills/migrate-profile/SKILL.md`):

1. Resolve source profile (argument → CLAUDE.md markers → preferences).
2. Load target profile by name.
3. Compute diff via `bin/switch-profile.sh --dry-run`.
4. Preview and confirm before applying.

Exit codes:
- `0` — migration completed (or profiles identical)
- `1` — error (profile not found, target not a directory)

See also:
- `/nyann:inspect-profile` — view current profile details
- `/nyann:doctor` — check repo health after migration
- `/nyann:bootstrap` — full project setup
