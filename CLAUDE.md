# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`nyann` is a Claude Code plugin that sets up and maintains project governance: git workflow, hooks, branching, commits, releases, CI, docs routing, and health monitoring. See `CHANGELOG.md` for release history.

Build / lint / test commands:
- `bats tests/bats/` unit + integration suite
- `./tests/lint.sh` shellcheck + SKILL.md length enforcement (also available as `shellcheck bin/*.sh`)
- `claude plugin validate .` manifest validation
- `evals/run.sh` skill-level trigger + output-quality evals (run locally; not a PR gate)

## Architecture at a glance

Four logical layers. Keep the boundaries clean:

1. **Skill layer** (`skills/*/SKILL.md`) Claude Code entry points. UX only: trigger, confirm, report. **No business logic.**
2. **Orchestrator layer** every `bin/<name>.sh` that a skill shells into is an orchestrator (e.g. `bootstrap.sh`, `retrofit.sh`, `doctor.sh`, `release.sh`, `pr.sh`, `commit.sh`, `new-branch.sh`, `sync.sh`, `undo.sh`, `setup.sh`, `switch-profile.sh` — driven by `skills/migrate-profile/`). Top-level coordinators that compose subsystems and own the user-facing JSON contract. Orchestrators that hand-build an `ActionPlan` and feed it to `bootstrap.sh` MUST also pass `--plan-sha256` (computed via `bin/preview.sh --emit-sha256`) so the integrity binding stays intact.
3. **Subsystem layer** the remaining `bin/*.sh` scripts (e.g. `detect-stack.sh`, `recommend-branch.sh`, `install-hooks.sh`, `compute-drift.sh`, `gen-claudemd.sh`, `preview.sh`, `_lib.sh`, `session-check.sh`). Focused utilities that emit/consume JSON schemas. **Subsystems do not call orchestrators** — when a subsystem needs a drift report, it calls `compute-drift.sh` directly rather than going through `doctor.sh`.
4. **Data + templates** (`profiles/`, `templates/`, `schemas/`) plus user profiles at `~/.claude/nyann/profiles/`.

All decisions and mutations live in shell scripts so the plugin is testable without Claude Code. Scripts communicate via JSON schemas defined in `schemas/` (StackDescriptor, BranchingChoice, Profile, ActionPlan, DriftReport, DocumentationPlan, LinkCheckReport, OrphanReport).

**MCP boundary:** shell scripts never invoke MCP tools. `bin/detect-mcp-docs.sh` only reads config; actual MCP calls (Obsidian / Notion page creation, link verification) are executed by the skill layer, which passes results back to bash.

## Non-negotiable conventions

- **Preview before mutate.** Every destructive path flows through `bin/preview.sh` (ActionPlan → diff → user confirmation). Never silently write files.
- **Idempotent.** Re-running a bootstrap produces the same state. Merge / append existing configs; never overwrite user content without explicit consent.
- **Router-mode CLAUDE.md, not content dump.** Generated CLAUDE.md is ≤ 3 KB soft (8 KB hard). Regenerate only between `<!-- nyann:start -->` / `<!-- nyann:end -->` markers; preserve everything else verbatim. Tables, not prose, inside the block.
- **`memory/` is always local**, regardless of doc routing choice.
- **Profiles are data, never code.** Strict schema validation on every load path (`profiles/_schema.json`). No `eval` of profile content, no embedded scripts, no remote code exec.
- **`gh` integration is always best-effort.** Guard on `command -v gh && gh auth status`; skip with a logged reason if either fails. Never fatal, never prompt for credentials.
- **No internal references in code.** This is a public project. Never use internal tracking IDs in comments, function names, test names, variable names, or sentinel filenames. Names must be self-descriptive. Traceability belongs in git history, not in the source.

## Skill authoring rules (apply to every `SKILL.md`)

- Body ≤ 500 lines. Longer detail → split into `skills/<skill>/references/<topic>.md`.
- Frontmatter `description` must be **pushy**: enumerate trigger phrases and scenarios aggressively. Vague descriptions under-trigger.
- Imperative + explain-why. Every step says *what* and *because*, so Claude can adapt when the step doesn't fit.
- Progressive disclosure via `references/` (loaded on demand, e.g. per-stack notes).
- Bundled `scripts/` for repeated work.
- Never duplicate content between SKILL.md and references, or between skills.

## Scope reminders

- **Git only.** No Mercurial/SVN/Fossil.
- **GitHub only** for remote integration. GitLab/Bitbucket deferred.
- **No application scaffolding.** Not a `create-next-app` replacement.
- **No dependency management** beyond what hooks require.
- **No history rewrites.** Non-compliant past commits are flagged, not fixed.
- **Unix-first.** Windows (`.ps1` variants) deferred.
