# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`nyann` is a Claude Code plugin that sets up and maintains project governance: git workflow, hooks, branching, commits, releases, CI, docs routing, and health monitoring. See `CHANGELOG.md` for release history.

Build / lint / test commands:
- `bats tests/bats/` unit + integration suite
- `./tests/lint.sh` shellcheck + SKILL.md length enforcement (also available as `shellcheck bin/*.sh`)
- `claude plugin validate .` manifest validation
- `evals/run.sh` skill-level trigger + output-quality evals (run locally; not a PR gate)

## Commit & PR conventions

- **Never add Claude Code attribution.** No `🤖 Generated with [Claude Code]` line and no `Co-Authored-By: Claude` trailer — in commit messages **or** PR/issue bodies. (`includeCoAuthoredBy: false` handles commit trailers, but PR body text is hand-authored, so this rule covers it.)
- Conventional Commits; release titles are version-only (e.g. `v1.6.0`), detail in the body.

## Architecture & conventions

Detailed docs (Project Memory):

| Topic | Where |
|---|---|
| Layer model + JSON schema contracts + MCP boundary | [`docs/architecture.md`](./docs/architecture.md) |
| Non-negotiable conventions (preview-before-mutate, idempotency, router-mode, profiles-as-data, no internal refs) | [`docs/principles/conventions.md`](./docs/principles/conventions.md) |
| Documentation principles + Project Memory model | [`docs/principles/documentation.md`](./docs/principles/documentation.md) |
| Release procedure | [`docs/RELEASING.md`](./docs/RELEASING.md) |

Read these before making changes that cross layers, touch generated files, or alter the doc structure.

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
