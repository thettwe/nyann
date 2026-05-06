# Non-negotiable conventions

These are the rules every change to nyann must respect. Breaking any
of them is a structural defect, not a stylistic difference.

## Preview before mutate

Every destructive path flows through `bin/preview.sh`
(ActionPlan → diff → user confirmation). **Never silently write
files.**

## Idempotent

Re-running a bootstrap produces the same state. Merge / append
existing configs; never overwrite user content without explicit
consent.

## Router-mode CLAUDE.md, not content dump

Generated CLAUDE.md is ≤ 3 KB soft, ≤ 8 KB hard. Regenerate only
between `<!-- nyann:start -->` / `<!-- nyann:end -->` markers;
preserve everything else verbatim. Tables, not prose, inside the
block.

This applies to nyann's own CLAUDE.md as well as the ones it
generates.

## `memory/` is always local

Regardless of doc-routing choice (local / Obsidian / Notion), the
`memory/` folder is local. It is the ephemeral team-shared scratch
layer; remote-routing it would defeat its purpose.

See [`documentation.md`](./documentation.md) for the full
Project Memory layered model.

## Profiles are data, never code

Strict schema validation on every load path
(`profiles/_schema.json`). No `eval` of profile content, no
embedded scripts, no remote code execution.

## `gh` integration is always best-effort

Guard on `command -v gh && gh auth status`; skip with a logged
reason if either fails. **Never fatal, never prompt for
credentials.** This applies to every gh-using path: PR creation,
ship, GitHub release creation, branch protection audit, tag
protection.

## No internal references in code

This is a public project. Never use internal tracking IDs in
comments, function names, test names, variable names, or sentinel
filenames. Names must be self-descriptive. Traceability belongs in
git history, not in the source.

## See also

- [Architecture](../architecture.md) — how the layers fit together
- [Documentation principles](./documentation.md) — the Project
  Memory model
