---
name: nyann:add-team-source
description: >
  Register a team-profile git source in ~/.claude/nyann/config.json.
  Idempotent upsert on --name.
arguments:
  - name: name
    description: Short slug (becomes the namespace prefix, e.g. `platform-team/base`).
    optional: false
  - name: url
    description: Any git-cloneable URL.
    optional: false
  - name: ref
    description: Branch or tag. Default `main`.
    optional: true
  - name: interval
    description: Sync interval in hours. Default 24.
    optional: true
---

# /nyann:add-team-source

Wraps `bin/add-team-source.sh`. Does not pull — registration only. Run `/nyann:sync-team-profiles` to fetch. See `skills/add-team-source/SKILL.md` for the upsert semantics and hand-off routing.
