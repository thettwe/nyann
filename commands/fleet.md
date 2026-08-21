---
name: nyann:fleet
description: >
  Manage the fleet registry of local repos and show the cross-repo health
  dashboard — per-repo score, trend sparkline, drift counts, worst
  category, sorted worst-first. Read-only: it audits and reports, never
  remediates (that's /nyann:fleet-retrofit).
arguments:
  - name: add
    description: Add a local repo path to the fleet registry (idempotent; pair with --name/--repo/--profile/--tag, or --watch to also mirror into the CI watch-list).
    optional: true
  - name: remove
    description: Remove an entry by name or path.
    optional: true
  - name: scan
    description: Discover git repos under a directory (preview first; --apply registers them).
    optional: true
  - name: cached
    description: Instant dashboard from each repo's persisted health history instead of a live audit (stale entries flagged).
    optional: true
  - name: drift
    description: Append repo-tagged drift findings per drifted repo (live mode only).
    optional: true
  - name: markdown
    description: Emit a paste-ready markdown table for team channels.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/fleet/SKILL.md` for the full flow.


# /nyann:fleet

Wraps `bin/fleet.sh` (registry CRUD: `--add`/`--remove`/`--list`/`--scan`/
`--prune`/`--suggest-org`) and `bin/fleet-doctor.sh` (bulk audit +
dashboard). The registry lives at `~/.claude/nyann/fleet.json` — LOCAL
working-copy paths, distinct from the sentinel watch-list (GitHub slugs);
an entry's optional `repo` slug joins the two (`--watch` mirrors it).

Dashboard default is a live per-repo `doctor` pass (worst-of exit codes
0/4/5); `--cached` reads persisted `memory/health.json` scores instantly
with staleness flags; `--drift`/`--explain` roll repo-tagged findings up
into one view. Registry scans and prunes preview first and only write with
`--apply`.

See also:
- `/nyann:fleet-retrofit` — bulk remediation once the dashboard shows drift.
- `/nyann:doctor` — the single-repo deep dive.
- `/nyann:watch` — CI/PR watching across repos (remote state, not governance).
