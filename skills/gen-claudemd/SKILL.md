---
name: gen-claudemd
description: >
  Regenerate the nyann-managed block in CLAUDE.md from the current profile,
  stack detection, and doc plan — without re-running a full bootstrap or
  retrofit. TRIGGER when the user says "regenerate CLAUDE.md",
  "update CLAUDE.md", "refresh CLAUDE.md", "rebuild CLAUDE.md",
  "re-gen CLAUDE.md", "my CLAUDE.md is stale", "CLAUDE.md doesn't match
  my profile", "sync CLAUDE.md with the profile", "/nyann:gen-claudemd".
  Do NOT trigger on "optimize CLAUDE.md" / "trim CLAUDE.md" / "what's
  unused" — that's the `optimize-claudemd` skill (usage-analytics-driven).
  Do NOT trigger on "explain CLAUDE.md" / "what's in CLAUDE.md" — that's
  `explain-state`. Do NOT trigger on initial project setup — that's
  `bootstrap-project`.
---

# gen-claudemd

Standalone CLAUDE.md regeneration. Wraps `bin/gen-claudemd.sh` with the
same inputs bootstrap uses, but skips the full bootstrap pipeline so the
user can refresh CLAUDE.md after changing their profile, adding docs, or
restructuring workspaces.

## 1. Gather inputs

The generator needs three inputs. Resolve them in this order:

1. **Profile** — resolve the active profile via preferences or CLAUDE.md
   markers; load with `bin/load-profile.sh <name>`. If the user names a
   specific profile, use that instead.
2. **Doc plan** — the generator needs a DocumentationPlan. To preserve
   the repo's existing doc routing (local / Obsidian / Notion / split),
   re-derive the plan using the same routing the user originally chose.
   Check `profile.documentation.storage_strategy`; if it names a
   non-local backend, also run `bin/detect-mcp-docs.sh` and pass
   `--mcp-targets` to route-docs. For local-only repos (the common
   case): `bin/route-docs.sh --profile <profile-path>` suffices.
   Write the resulting DocumentationPlan JSON to a temp file.
3. **Stack** (optional but recommended) — run `bin/detect-stack.sh --path .`
   for a StackDescriptor JSON. Write it to a temp file. Skip if
   detection fails (gen-claudemd falls back to profile-only data).

For monorepos, also resolve workspace configs:
```
bin/resolve-workspace-configs.sh --stack <stack-path> --profile <profile-path>
```
Pass the result via `--workspace-configs <path>`.

## 2. Snapshot the current state

Before running the generator, capture the existing managed block so
you can show a before/after diff. If CLAUDE.md exists with markers,
read the content between `<!-- nyann:start -->` and
`<!-- nyann:end -->`. If no markers exist, note that a new block will
be appended.

## 3. Confirm before writing

Ask: "Regenerate the nyann-managed block in CLAUDE.md?"

Show what will feed into the generation (profile name, stack,
storage strategy) so the user can verify the inputs are correct.
Skip the confirmation only when the user said "just do it".

## 4. Run the generator

On confirmation:

```
bin/gen-claudemd.sh \
  --profile <profile-path> \
  --doc-plan <doc-plan-path> \
  [--stack <stack-path>] \
  [--workspace-configs <ws-path>] \
  [--project-name <name>] \
  --target <cwd>
```

The script writes CLAUDE.md in-place — content outside markers is
preserved verbatim.

If the script warns about the 3 KB soft cap, relay the warning and
suggest `/nyann:optimize-claudemd` as a follow-up.

If the script refuses at the 8 KB hard cap, explain and offer
`--force` to override.

## 5. Report

- Before/after diff of the managed block.
- Byte count of the managed block.
- Whether user content outside markers was preserved (always yes).

## When to hand off

- "Optimize CLAUDE.md based on usage" → `optimize-claudemd` skill.
- "What does nyann see in this repo?" → `explain-state` skill.
- "Check if my repo is healthy" → `doctor` skill.
- "Switch to a different profile" → `migrate-profile` skill
  (which calls gen-claudemd internally after the switch).
