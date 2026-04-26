---
name: nyann:learn-profile
description: >
  Inspect a reference repo and save its nyann-relevant setup (stack,
  hooks, branching, commit convention, extras) as a reusable profile.
arguments:
  - name: target
    description: Path to the reference repo to learn from. Defaults to the current working directory.
    optional: true
  - name: name
    description: Name to save the profile under (lowercase-kebab). Defaults to the repo's basename.
    optional: true
  - name: user-root
    description: Override `~/.claude/nyann` profile root.
    optional: true
---

# /nyann:learn-profile

Wraps `bin/learn-profile.sh`. Read-only on the reference repo; writes one JSON profile under `~/.claude/nyann/profiles/`. Never modifies the reference repo itself.

See `skills/learn-profile/SKILL.md` for trigger phrases and DISAMBIGUATION from `inspect-profile` (reads a profile file, not a repo) and `bootstrap-project` (applies a profile, not learns one).
