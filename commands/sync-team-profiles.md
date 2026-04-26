---
name: nyann:sync-team-profiles
description: >
  Clone/update registered team-profile sources and register valid profiles
  under a namespace. Respects the per-source sync interval unless --force.
arguments:
  - name: force
    description: Ignore the interval gate and re-sync every source.
    optional: true
  - name: name
    description: "Sync only the named source. Default: all registered sources."
    optional: true
---

# /nyann:sync-team-profiles

Wraps `bin/sync-team-profiles.sh`. Clones or `git pull --depth=1`s each registered source, validates profiles against `profiles/_schema.json`, and registers valid ones as `<source>/<profile>`.

See `skills/sync-team-profiles/SKILL.md` for interval semantics, per-source isolation, and hand-off to `inspect-profile` / `bootstrap-project`.
