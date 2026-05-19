---
name: nyann:gen-devcontainer
description: >
  Scaffold a `.devcontainer/devcontainer.json` keyed to the project's
  primary language. Preview-by-default; idempotent on apply (refuses
  to overwrite a diverged config without `--force-overwrite`).
arguments:
  - name: language
    description: One of node, python, go, rust, dart, java, dotnet, php, ruby, swift, elixir, cpp.
  - name: name
    description: Display name (default - repo basename / `<language>-devcontainer`).
    optional: true
  - name: target
    description: Repo to write to. Required only with `--apply`.
    optional: true
  - name: apply
    description: Write the config; default is preview-to-stdout.
    optional: true
  - name: force-overwrite
    description: Overwrite an existing devcontainer.json that differs from the rendered output. Without it, exits 3 after printing a diff.
    optional: true
  - name: port
    description: Repeatable. Forward a port from the container to the host (1-65535).
    optional: true
  - name: feature
    description: Repeatable. Extra devcontainer feature ref (include version pin).
    optional: true
  - name: extension
    description: Repeatable. Extra VS Code extension ID (`publisher.extension`).
    optional: true
  - name: post-create-command
    description: Override the default per-language postCreateCommand.
    optional: true
  - name: cpus
    description: Codespaces hostRequirements.cpus (2-32).
    optional: true
  - name: memory
    description: Codespaces hostRequirements.memory (e.g. `4gb`).
    optional: true
  - name: storage
    description: Codespaces hostRequirements.storage (e.g. `16gb`).
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:gen-devcontainer

Wraps `bin/gen-devcontainer.sh`. Emits a devcontainer.json keyed to a
primary language; preview-by-default; idempotent on apply.

For language-picking guidance (mapping from StackDescriptor) and the
shape of the rendered output, see
`skills/gen-devcontainer/SKILL.md`.
