---
name: nyann:route-docs
description: >
  Change documentation storage routing (local, Obsidian, Notion, or
  per-type split) and regenerate the doc scaffold to match.
arguments:
  - name: routing
    description: >
      Routing spec. Examples: `all:local`, `all:obsidian`,
      `prd:notion,adrs:obsidian,research:local`. Unmentioned types fall
      back to local. `memory` is always local.
    optional: true
  - name: obsidian-vault
    description: Obsidian vault name (required when routing any target to Obsidian).
    optional: true
  - name: obsidian-folder
    description: Folder path within the Obsidian vault.
    optional: true
  - name: notion-parent
    description: Notion parent page ID or URL (required when routing any target to Notion).
    optional: true
  - name: mcp-targets
    description: Path to MCP doc-targets JSON from `bin/detect-mcp-docs.sh`. Required when routing any target to a non-local backend (Obsidian/Notion); the script validates chosen backends against `available[]`.
    optional: true
  - name: project-name
    description: Override the project name used in scaffolded templates.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:route-docs

Composes `bin/route-docs.sh` (DocumentationPlan) and
`bin/scaffold-docs.sh` (local file creation) for post-bootstrap doc
routing changes.

## When to invoke

- Switching from local docs to Obsidian or Notion.
- Changing per-type routing (e.g. PRDs to Notion, ADRs to Obsidian).
- Regenerating the doc scaffold after restructuring.

## Output

1. A DocumentationPlan JSON showing each doc type and its target.
2. Scaffold-docs creates missing local files (idempotent — existing
   files are never overwritten).
3. MCP-routed targets are flagged for manual creation via the
   configured MCP server.

## Storage strategies

| Spec | Strategy |
|---|---|
| `all:local` | `local` |
| `all:obsidian` | `obsidian` |
| `all:notion` | `notion` |
| mixed per-type | `split` |

See also:
- `/nyann:gen-claudemd` — refresh CLAUDE.md after rerouting
- `/nyann:bootstrap` — initial project setup (includes routing)
- `/nyann:doctor` — audit repo health including doc completeness
