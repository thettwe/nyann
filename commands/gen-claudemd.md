---
name: nyann:gen-claudemd
description: >
  Regenerate the nyann-managed block in CLAUDE.md from the current profile
  and stack detection without running a full bootstrap.
arguments:
  - name: profile
    description: Override the active profile name (e.g. `--profile fastapi-service`). Defaults to the profile resolved from preferences or CLAUDE.md markers.
    optional: true
  - name: project-name
    description: Override the project name used in the generated block. Defaults to the repo directory basename.
    optional: true
  - name: force
    description: Bypass the 8 KB hard cap on the managed block.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:gen-claudemd

Wraps `bin/gen-claudemd.sh`. Regenerates only the `<!-- nyann:start -->`
/ `<!-- nyann:end -->` block; user content outside markers is preserved
verbatim.

## When to invoke

- Profile changed and CLAUDE.md is stale → run this.
- Added new docs or restructured workspaces → run this.
- After `/nyann:migrate-profile` if CLAUDE.md wasn't auto-refreshed.

## Output

The managed block is rewritten in-place. Reports byte count and whether
the soft cap (3 KB) was exceeded.

## Size budgets

- **3 KB soft**: warning emitted; suggest `/nyann:optimize-claudemd`.
- **8 KB hard**: script refuses unless `--force` is passed.

See also:
- `/nyann:optimize-claudemd` — usage-analytics-driven pruning
- `/nyann:doctor` — audit repo health including CLAUDE.md size
- `/nyann:bootstrap` — initial full project setup
