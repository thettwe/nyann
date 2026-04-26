---
name: nyann:undo
description: >
  Safely undo the last commit (or last N commits) on a feature branch.
  Always previews first. Refuses main/master/develop, merge commits,
  and pushed commits (override with `--allow-pushed`).
arguments:
  - name: count
    description: Number of commits to undo. Default 1. >3 requires user confirmation.
    optional: true
  - name: strategy
    description: One of `soft` (default; stays staged), `mixed` (unstages), `hard` (discards).
    optional: true
  - name: allow-pushed
    description: Permit undoing a commit already on upstream (force-push required after).
    optional: true
  - name: dry-run
    description: Preview only — no mutation.
    optional: true
---

# /nyann:undo

Wraps `bin/undo.sh`. Flow:

1. Dry-run preview. Report which commits will be undone.
2. Confirm (always for non-soft or multi-commit).
3. Reset via `--strategy` (soft/mixed/hard).
4. Report new HEAD + where changes live.

See `skills/undo/SKILL.md` for DISAMBIGUATION against `git revert` (pushed commits) and merge-commit refusal.
