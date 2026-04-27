---
name: nyann:cleanup-branches
description: >
  Prune local branches whose work is already merged into the base. Lists
  candidates first, then applies on `--yes`. Mirrors the safe-delete
  semantics of `git branch -d` (lowercase d): nothing unmerged is touched.
arguments:
  - name: yes
    description: If passed, executes the deletions. Without `--yes`, the command emits the candidate list as a preview and exits 0.
    optional: true
  - name: dry-run
    description: Same JSON shape as preview, but mode reads `dry-run` instead — useful in scripts that want to confirm "I would delete X" without running.
    optional: true
  - name: base
    description: Branch to use as the merge target. Defaults to the profile's primary base branch (auto-resolved through `origin/HEAD`, `main`, or `master`).
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:cleanup-branches

Wraps `bin/cleanup-branches.sh`. Same `--yes`-required-to-mutate
contract as `/nyann:undo` and `/nyann:migrate-profile`.

## When to invoke

- "clean up branches" / "delete merged branches" / "prune local branches" → run this.
- "I see N merged branches in `/nyann:doctor`'s output" → exact same flow.

## Output

A CleanupBranchesResult JSON:

| Mode | Triggered by | What happens |
|---|---|---|
| `preview` | (default) | List candidates + warn "re-run with --yes". Nothing deleted. |
| `dry-run` | `--dry-run` | Same shape, no warn. Nothing deleted. |
| `applied` | `--yes` | `git branch -d` per candidate. Failures land in `errors[]`. |

## Safety

- `git branch -d` (lowercase d) refuses to delete an unmerged
  branch even if the candidate list says it should be safe — race
  conditions between preview and apply can't drop unmerged work.
- Current branch and base branch are never candidates.
- Remote-tracking refs aren't touched. Use `git push --delete origin
  <branch>` separately if you want to mirror to the remote.

See also:
- `/nyann:doctor` — shows the merged-branch count alongside other
  hygiene signals.
- `/nyann:undo` — undo the last commit (different shape, same
  preview-mutate contract).
