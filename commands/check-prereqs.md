---
name: nyann:check-prereqs
description: >
  Survey the machine and report which nyann features are usable right now.
  Classifies requirements as hard (nyann won't run without them) vs soft
  (feature-gated; graceful skip with a clear reason). Read-only; never
  installs anything.
arguments:
  - name: json
    description: If passed, emit the probe results as JSON instead of the human table.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:check-prereqs

Wraps `bin/check-prereqs.sh`. Useful before the first `/nyann:bootstrap`
on a new machine — lets the user see which stacks are installable and
which will skip-with-reason.

## Classification

- **hard**: `git`, `jq`, `bash`. nyann exits 1 on any mutating command
  without these.
- **soft**: stack toolchains (`node`, `pnpm`, `npm`, `go`, `cargo`),
  integration helpers (`gh`, `gitleaks`, `pre-commit`, `uv`), and
  dev-only tooling (`shellcheck`, `bats`). Each is scoped to specific
  features; nyann degrades or skip-with-reasons when they're absent.

## Output

Human-readable table by default. `/nyann:check-prereqs --json` emits
a structured `prereqs[]` array (`{kind, tool, status, version, hint}`)
for scripting.

## When to use

- First-time setup: "what do I need to install before bootstrapping?"
- Before opening an issue: paste the output so the maintainer can see
  which tools are present.
- In a team profile dry-run: confirm every teammate's machine has the
  tools a profile expects.
