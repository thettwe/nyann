# Contributing to nyann

Thanks for considering a contribution. nyann is a public Claude Code plugin for project governance — see [README.md](README.md) for what it does and [CLAUDE.md](CLAUDE.md) for the architectural rules every change has to respect.

## Quick start

```sh
git clone https://github.com/thettwe/nyann ~/code/nyann
cd ~/code/nyann

# Install the prereqs nyann itself depends on:
brew install bats-core shellcheck jq uv   # macOS
# or apt-get install bats shellcheck jq + brew/pip for the others

# Run the full check suite:
./tests/lint.sh        # shellcheck + SKILL.md length
bats tests/bats/        # full bats suite (654 tests as of v1.0.0)
```

A change is ready to land when both pass and the `## [Unreleased]` section of `CHANGELOG.md` describes the user-visible effect. (After v1.0.0 ships, contributors add a fresh `## [Unreleased]` section above the `## [1.0.0]` entry; the release ritual in `docs/RELEASING.md` handles the version-bump rename.)

## Architecture rules (non-negotiable)

These are enforced on every PR. See [CLAUDE.md](CLAUDE.md) "Non-negotiable conventions" for the full list:

1. **Preview before mutate.** Every destructive path flows through `bin/preview.sh` (ActionPlan → diff → user confirmation).
2. **Idempotent.** Re-running a bootstrap produces the same state. Never overwrite user content without explicit consent (`--allow-merge-existing`).
3. **Profiles are data, never code.** No `eval`, no embedded scripts, no remote includes.
4. **`gh` integration is always best-effort.** Skip with a logged reason; never fatal, never prompt for creds.
5. **MCP boundary.** Shell scripts never invoke MCP tools — only the skill layer does.
6. **No internal references in code.** Names must be self-descriptive. Traceability belongs in git history.

## Layer model

Four layers, kept clean — see [CLAUDE.md](CLAUDE.md) "Architecture at a glance":

1. **Skill layer** — `skills/*/SKILL.md` — Claude Code entry points. UX only.
2. **Orchestrator layer** — `bin/<name>.sh` shadowed by a skill. Composes subsystems; owns the user-facing JSON contract.
3. **Subsystem layer** — focused utilities (`bin/detect-stack.sh`, `bin/compute-drift.sh`, `bin/preview.sh`, `bin/_lib.sh`). Subsystems do not call orchestrators.
4. **Data + templates** — `profiles/`, `templates/`, `schemas/`.

A subsystem that calls an orchestrator is rejected on review. An orchestrator that hand-builds an `ActionPlan` and feeds it to `bootstrap.sh` MUST also pass `--plan-sha256` (computed via `bin/preview.sh --emit-sha256`).

## Skill authoring

If you're adding or changing a `skills/<name>/SKILL.md`:

- Body ≤ 500 lines (lint enforces). Longer detail → `skills/<name>/references/<topic>.md`.
- Frontmatter `description` must be **pushy**: enumerate trigger phrases AND `Do NOT trigger on …` disambiguation against neighbouring skills. Vague descriptions under-trigger.
- Add or update the matching `commands/<name>.md` so the slash command catalog stays at parity with skills.
- Add a trigger-discrimination eval spec at `evals/<name>.evals.json` (see existing specs for the format).

## Schema contract

If you add a JSON-emitting `bin/*.sh` or change an existing one's output shape:

- The shape needs a schema in `schemas/<name>.schema.json` with `additionalProperties: false`.
- Add a producer→validate test in `tests/bats/test-schema-validation.bats`.
- Add the row to `schemas/README.md` (the `test-public-surface-counts.bats` lock asserts every schema is documented).

The schema is the contract. A field rename without a schema bump breaks downstream consumers silently — do not do this.

## Pull request flow

1. **Branch off `main`.** Use `bin/new-branch.sh` (or `/nyann:branch <purpose> <slug>`) so the name matches the project's branching strategy.
2. **Commit in Conventional Commits.** Use `bin/commit.sh` (or `/nyann:commit`) — it generates the message from the staged diff and runs the commit-msg hook.
3. **Run `./tests/lint.sh && bats tests/bats/` locally** before pushing. CI runs the same suite on ubuntu + macos but local runs catch issues faster.
4. **Update `CHANGELOG.md`** under `[Unreleased]`. Pick the right sub-section (`Added` / `Changed` / `Fixed` / `Security`); keep entries one line where possible.
5. **Open the PR with `bin/pr.sh` (or `/nyann:pr`).** Title in Conventional-Commits style; body should reference any closed issues and call out user-visible behaviour changes explicitly.
6. **Squash-merge is the default.** Atomic commits inside the PR are encouraged for review readability; the squash collapses them to a single line on `main`.

## Reporting bugs vs reporting security issues

- **Bugs** → open an issue at <https://github.com/thettwe/nyann/issues>.
- **Security vulnerabilities** → see [SECURITY.md](SECURITY.md). Do not open public issues for these.

## License

By contributing, you agree your changes are licensed under the same MIT license as the rest of the project (see [LICENSE](LICENSE)).
