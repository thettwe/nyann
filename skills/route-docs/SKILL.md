---
name: route-docs
description: >
  Change where project documentation is stored — local files, Obsidian
  vault, Notion workspace, or a per-type split — and regenerate the doc
  scaffold to match. TRIGGER when the user says "change doc routing",
  "switch docs to Obsidian", "move docs to Notion", "route docs locally",
  "change documentation storage", "reroute docs", "switch from local to
  Obsidian", "set up doc routing", "change where docs are stored",
  "/nyann:route-docs".
  Do NOT trigger on "bootstrap this project" — bootstrap runs doc routing
  as one step of the full pipeline. Do NOT trigger on "generate CLAUDE.md"
  — that's `gen-claudemd`. Do NOT trigger on "optimize CLAUDE.md" —
  that's `optimize-claudemd`.
---

# route-docs

Standalone doc-routing and scaffold regeneration. Composes
`bin/route-docs.sh` (produces a DocumentationPlan) and
`bin/scaffold-docs.sh` (materializes the local-target portion) so the
user can change doc storage after initial bootstrap without
re-running the full pipeline.

## 1. Resolve profile and current state

1. Load the active profile via `bin/load-profile.sh <name>`.
2. Run `bin/detect-stack.sh --path .` for a StackDescriptor (optional;
   used by scaffold-docs for stack-aware architecture templates).
3. Check which doc targets already exist (`docs/`, `memory/`,
   `docs/decisions/`, etc.) so the user sees what will change.

## 2. Determine the routing spec

The user's intent maps to a `--routing` value:

| User says | Routing spec |
|---|---|
| "everything local" | `all:local` (default) |
| "docs in Obsidian" | `all:obsidian` |
| "docs in Notion" | `all:notion` |
| "PRDs in Notion, ADRs in Obsidian, rest local" | `prd:notion,adrs:obsidian,research:local,architecture:local` |

If the user's intent is ambiguous, use `AskUserQuestion` to pick:

- header: "Routing"
- options:
  - "Local (Recommended)" — docs/ directory in the repo
  - "Obsidian" — route to an Obsidian vault via MCP
  - "Notion" — route to a Notion workspace via MCP
  - "Custom split" — different backend per doc type

`memory` is always local regardless of routing.

For any non-local routing, first run `bin/detect-mcp-docs.sh` to
discover available MCP connectors. The result is an MCP doc-targets
JSON; pass it to route-docs via `--mcp-targets <path>`. Without this,
route-docs will reject non-local backends because it validates each
chosen backend against `--mcp-targets.available[]`.

For MCP-routed targets, also collect the required parameters:
- **Obsidian**: `--obsidian-vault <name>` and optionally
  `--obsidian-folder <path>`.
- **Notion**: `--notion-parent <id-or-url>`.

## 3. Preview the plan

Run route-docs in preview mode:

```
bin/route-docs.sh \
  --profile <profile-path> \
  [--routing <spec>] \
  [--mcp-targets <mcp-doc-targets.json>] \
  [--obsidian-vault <name>] [--obsidian-folder <path>] \
  [--notion-parent <id>] \
  [--project-name <name>]
```

Output is a DocumentationPlan JSON
(`schemas/documentation-plan.schema.json`). Show the user:

- Each doc type (architecture, prd, adrs, research, memory) and its
  target (local path, obsidian, notion).
- The computed `storage_strategy` (local / obsidian / notion / split).
- Which local files will be created by the scaffolder.
- Which MCP targets require skill-layer creation (Obsidian pages,
  Notion databases).

## 4. Scaffold local targets

On confirmation:

```
bin/scaffold-docs.sh \
  --plan <plan-path> \
  [--stack <stack-path>] \
  [--project-name <name>] \
  --target <cwd>
```

The scaffolder is idempotent — existing files are never overwritten.
Only gaps get filled.

For MCP-routed targets (type != local), scaffold-docs skips them with
a note. The skill layer handles MCP page creation via the configured
MCP server (Obsidian / Notion) as documented in
`skills/bootstrap-project/references/mcp-routing.md`.

## 5. Regenerate CLAUDE.md

After the scaffold, the CLAUDE.md doc-map table may be stale.
Suggest running `/nyann:gen-claudemd` to refresh the managed block
with the new routing.

## 6. Report

- Doc types and their new targets.
- Files created by scaffold-docs.
- MCP targets that need manual page creation (if any).
- Storage strategy summary.

## When to hand off

- "Regenerate CLAUDE.md with the new routing" → `gen-claudemd` skill.
- "Check repo health after rerouting" → `doctor` skill.
- "Set up the full project from scratch" → `bootstrap-project` skill.
- "Create Obsidian/Notion pages" → the MCP creation flow is documented
  in `skills/bootstrap-project/references/mcp-routing.md`; follow
  those instructions for the non-local targets.
