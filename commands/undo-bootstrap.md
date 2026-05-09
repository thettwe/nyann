---
name: nyann:undo-bootstrap
description: >
  Reverse a bootstrap or retrofit run captured in a BootRecord manifest.
  Restores pre-state files, drops created branches, and reports anything
  it couldn't safely undo. Always previews first; refuses to clobber files
  the user edited after bootstrap (override with --force).
arguments:
  - name: manifest
    description: Path to a specific BootRecord manifest. Default uses the newest under memory/.nyann/bootstraps/.
    optional: true
  - name: scope
    description: CSV of categories to undo (any of docs, hooks, branching, gitignore, editorconfig, github, all). Default all.
    optional: true
  - name: force
    description: Override "modified after bootstrap" refusal — overwrite local edits.
    optional: true
  - name: allow-rebase
    description: Allow undo when HEAD has commits stacked on top of the bootstrap seed.
    optional: true
  - name: allow-non-empty-branches
    description: Allow undo of long-lived branches that have new commits past base_sha.
    optional: true
  - name: dry-run
    description: Preview only — no mutation.
    optional: true
  - name: keep-record
    description: Keep the manifest dir after a successful undo (defaults to removing it).
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:undo-bootstrap

Wraps `bin/undo-bootstrap.sh`. Flow:

1. Locate the BootRecord (newest under `memory/.nyann/bootstraps/`, or
   `--manifest <path>` for a specific one).
2. Dry-run preview the reversal: what will be restored, deleted, dropped.
3. Confirm with the user. Walk skipped[] entries and explain each.
4. Execute with `--yes`. Report the result.

See `skills/undo-bootstrap/SKILL.md` for DISAMBIGUATION against
`/nyann:undo` (commit-undo, different scope) and the override-flag
semantics.
