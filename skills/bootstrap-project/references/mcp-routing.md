# MCP doc routing (Obsidian / Notion)

Load this file when `bin/detect-mcp-docs.sh` reports at least one entry
in `available[]` and the user wants to route documentation into that
connector instead of (or in addition to) local files.

The skill layer does the actual MCP tool calls — bash scripts only
produce the `DocumentationPlan` that this flow consumes, then update
it with the concrete identifiers you receive back.

## 1. Decide the routing

Inputs:

- `bin/detect-mcp-docs.sh` output → `available[]`.
- User preference — always ask. Don't silently pick an MCP even if only
  one is available.

Ask the user exactly one of:

- **Obsidian only available** — "Store docs in your Obsidian vault, or
  keep them local in this repo?"
- **Notion only available** — same question with Notion.
- **Both available** — "Store docs locally, in Obsidian, in Notion, or
  split across them?" If they pick split, follow up with "Which doc
  types go where? PRD / ADRs / research / architecture each need an
  answer."

Capture the answers into a `--routing` string for `bin/route-docs.sh`:

- All local:    `all:local`          (or omit the flag)
- All Obsidian: `all:obsidian`
- All Notion:   `all:notion`
- Split:        `prd:notion,adrs:obsidian,research:local,architecture:local`

Memory is always local by invariant — don't ask about it.

## 2. Collect connector targets

Before calling `route-docs.sh`, gather the extra inputs each MCP needs:

### Obsidian

Ask:

- **Vault name** (`--obsidian-vault`). Required. Example: `work`.
- **Folder path inside vault** (`--obsidian-folder`). Optional.
  Default: `projects/<project_name>/` (the router appends the
  doc-type-specific leaf: `architecture`, `prd`, `decisions`, `research`).

### Notion

Ask:

- **Parent page ID or URL** (`--notion-parent`). Required. Accept either
  the 32-char page ID or a full notion.so URL — the skill extracts the ID.

## 3. Produce the plan

Invoke the router with everything you gathered:

```sh
bin/route-docs.sh \
  --profile <profile> \
  --mcp-targets <detector-output> \
  --routing "<spec>" \
  --obsidian-vault <name> \
  --obsidian-folder <path> \
  --notion-parent <id> \
  --project-name <name>
```

The router validates that every routed MCP backend is actually in
`available[]` and that required connector args are present. On
mismatch it exits non-zero with a clear error — surface the error to
the user and re-ask, don't silently fall back.

## 4. Create the MCP-side files (skill-driven)

For each target in the plan where `type != "local"`, create the backing
storage via the MCP tool.

### Obsidian

Iterate `plan.targets` where `type == "obsidian"`. For each:

1. Render the template you'd have written locally (architecture.md,
   prd.md, etc.) in memory. Templates live under `templates/docs/`.
2. Invoke the connector's **create_vault_file** tool:
   ```json
   {"vault": "<vault>", "path": "<folder>/<leaf>.md", "content": "<rendered>"}
   ```
3. Capture the response. Update the plan:
   - Set `targets.<type>.file_path` to the path you just wrote.
   - Set `targets.<type>.link_in_claude_md` to
     `obsidian://vault/<vault>/<path>` (URL-encode spaces).

For directories (ADRs, research), create the index file first
(`README.md`), then any seed files (`ADR-000-*.md`). Two tool calls
per directory, no folder-creation call — vault files auto-create
parent folders.

### Notion

Iterate `plan.targets` where `type == "notion"`. For each:

1. Render the template as Markdown. Notion's MCP accepts Markdown
   bodies.
2. Invoke **pages.create** under `parent.page_id = <notion-parent>`:
   ```json
   {"parent": {"page_id": "<parent>"}, "properties": {"title": [{"type": "text", "text": {"content": "<title>"}}]}, "children": [{"type": "paragraph", ...}]}
   ```
   Or the richer Markdown-body form the MCP server exposes.
3. Capture the returned `id` + `url`. Update the plan:
   - `targets.<type>.page_id = <id>`
   - `targets.<type>.url = <url>`
   - `targets.<type>.link_in_claude_md = notion://page/<id>` (or `url`
     if the user's Notion client handles https:// better).

### Retries + cancellation

- On tool failure, retry once. On second failure, ask the user:
  "Fall back to local for this doc type?" If yes, rewrite that target
  to `{type:"local", path:"docs/..."}` in the plan and continue.
- If the user cancels mid-flow, **do not** undo pages/notes already
  created. Notion doesn't undelete well, and partial state is less
  confusing than "where did my notes go?". Report what succeeded.

## 5. Hand the plan back to scaffold-docs + gen-claudemd

Once the plan has concrete identifiers, downstream scripts work as usual:

- `bin/scaffold-docs.sh` still materializes local targets (including
  memory, which is never routed to an MCP).
- `bin/gen-claudemd.sh` reads `link_in_claude_md` on every target, so
  MCP-routed docs show up in the Docs map with `obsidian://` /
  `notion://` links.

## 6. Verifying MCP links later (doctor)

`bin/check-links.sh` classifies `obsidian://` / `notion://` URIs as
`needs_mcp_verify`. The skill layer runs that verification on doctor's
behalf:

1. For each `needs_mcp_verify[]` entry in the LinkCheckReport, call
   the matching connector's read/get tool:
   - Obsidian: **read_vault_file** with the vault + path from the URI.
   - Notion:   **pages.retrieve** with the page_id from the URI.
2. On not-found, reclassify the entry: push it into `broken[]` with
   `reason: "mcp-target-not-found"`.
3. On connector unreachable (network, auth expired, server offline),
   keep the entry where it is and surface a ⚠ "verification skipped,
   connector unavailable" instead of a ✗.

Never block doctor on MCP being unreachable — hygiene checks must
still run when the user is offline.

## Failure modes + messaging

- User selects Obsidian but the MCP isn't authenticated → surface the
  connector's error verbatim; suggest they `open vault '<name>' in
  Obsidian` and retry.
- User picks a vault that doesn't exist → suggest the vault list from
  `list_vault_files` so they can pick a real one.
- User's chosen Notion parent isn't reachable (permissions) → ask for
  a different parent.
- Plan contains mixed types but the user later wants to migrate →
  deferred to v2 (post-v1.0, see TECH Appendix C). Don't promise it.

## Boundaries

- Shell scripts never invoke MCP tools. This is a skill-layer
  responsibility; the orchestrator layer stays testable without a
  live connector.
- `memory/` never leaves local storage regardless of routing spec.
- Templates stay in `templates/docs/` — the skill renders them, then
  hands content to the MCP tool; no duplicate templates per backend.
