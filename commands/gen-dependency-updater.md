---
name: nyann:gen-dependency-updater
description: >
  Scaffold a Dependabot or Renovate config (`.github/dependabot.yml`
  or `renovate.json`) for the active stack. Preview-by-default;
  idempotent on apply (refuses to overwrite a diverged config without
  `--force-overwrite`).
arguments:
  - name: updater
    description: `dependabot` (per-ecosystem YAML) or `renovate` (single JSON).
  - name: ecosystem
    description: Repeatable. One of npm, pip, gomod, cargo, bundler, composer, maven, gradle, pub, nuget, mix, swift, docker, github-actions.
  - name: directory
    description: Manifest directory (starts with `/`). Default `/`. Place before the corresponding `--ecosystem` for monorepo workspaces.
    optional: true
  - name: target
    description: Repo to write to. Required only with `--apply`.
    optional: true
  - name: apply
    description: Write the config; default is preview-to-stdout.
    optional: true
  - name: force-overwrite
    description: Overwrite an existing config that differs from the rendered output. Without it, exits 3 after printing a diff.
    optional: true
  - name: schedule
    description: `daily` / `weekly` (default) / `monthly`.
    optional: true
  - name: grouping
    description: `off` / `minor-patch` (default) / `all`.
    optional: true
  - name: open-prs
    description: Max open updater PRs per ecosystem (1-25, default 5).
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:gen-dependency-updater

Wraps `bin/gen-dependency-updater.sh`. Emits a Dependabot or Renovate
config; preview-by-default; idempotent on apply.

For ecosystem-picking guidance (which ones to pair with which stacks)
and choosing between Dependabot vs Renovate, see
`skills/gen-dependency-updater/SKILL.md`.
