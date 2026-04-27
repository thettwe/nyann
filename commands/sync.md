---
name: nyann:sync
description: >
  Update the current feature branch against its base (rebase by default,
  merge on request). Refuses on main/master/develop or with a dirty tree.
arguments:
  - name: base
    description: Base branch to sync against. Defaults to upstream / origin HEAD / `main`.
    optional: true
  - name: merge
    description: Use merge strategy instead of rebase.
    optional: true
  - name: dry-run
    description: Show what would happen without mutating.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:sync

Wraps `bin/sync.sh`. Flow:

1. Guard: refuse on main/master/develop; require clean tree.
2. Fetch origin.
3. Resolve base (`--base` > `@{upstream}` > `origin/HEAD` > `main`).
4. Run `rebase` (default) or `merge`.
5. Emit JSON with status: `up-to-date` / `synced` / `dirty` / `skipped` / `conflicts`.
6. On conflicts, leave the tree in a rebase-in-progress / merge-in-progress state for manual resolution.

See `skills/sync/SKILL.md` for the full conflict-resolution handoff.
