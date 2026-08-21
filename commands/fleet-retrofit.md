---
name: nyann:fleet-retrofit
description: >
  Bulk remediation across the fleet registry: classify every repo (clean /
  drifted / ungoverned / error), then walk them worst-first fixing drift —
  and, with --bootstrap-missing, bootstrapping un-governed repos — with a
  preview and an explicit confirmation PER REPO. There is no "yes to all";
  each repo writes its own BootRecord and stays individually undoable.
arguments:
  - name: bootstrap-missing
    description: Also plan un-governed repos (no boot record, no resolvable profile) for a full bootstrap; without it they are listed and skipped.
    optional: true
  - name: tag
    description: Limit the run to fleet entries carrying this tag.
    optional: true
  - name: only
    description: Limit the run to a CSV of entry names.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/fleet-retrofit/SKILL.md` for the full flow.


# /nyann:fleet-retrofit

Wraps `bin/fleet-retrofit.sh` — a plan/record/finalize bookkeeping engine
that NEVER mutates a repo itself. `--plan` classifies the fleet read-only
(exit 0 = nothing to do, 4 = work pending); the skill layer then drives
the EXISTING single-repo machinery per repo (retrofit's remediation chain,
or bootstrap-project's for un-governed repos with `--bootstrap-missing`),
each behind its own preview + SHA-bound ActionPlan + confirmation;
`--record`/`--finalize` track outcomes into a FleetRunResult.

Safety: per-repo preview-and-confirm is structural (mutation only flows
through `preview.sh` → `bootstrap.sh --plan-sha256`), a non-interactive
context stops at the plan, failures are isolated per repo, and every
mutated repo is reversible via `/nyann:undo-bootstrap` in that repo.

See also:
- `/nyann:fleet` — the read-only dashboard that usually precedes this.
- `/nyann:retrofit` — the single-repo remediation this skill applies per repo.
- `/nyann:undo-bootstrap` — per-repo rollback of a fleet run's changes.
