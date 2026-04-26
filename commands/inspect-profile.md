---
name: nyann:inspect-profile
description: >
  Render a human-readable summary of what a nyann profile enables
  (stack, branching, hooks, extras, docs).
arguments:
  - name: name
    description: Profile name. User profiles shadow starter profiles with the same name.
    optional: false
  - name: user-root
    description: Override `~/.claude/nyann` profile root.
    optional: true
---

# /nyann:inspect-profile

Wraps `bin/inspect-profile.sh`. Read-only. Loads via `load-profile.sh` (user > starter) and prints sections: Profile/Stack/Branching/Hooks/Extras/Conventions/Documentation/GitHub integration.

See `skills/inspect-profile/SKILL.md` for DISAMBIGUATION from `explain-state` (reads the repo, not a profile file).
