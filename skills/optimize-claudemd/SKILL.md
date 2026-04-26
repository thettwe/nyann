---
name: optimize-claudemd
description: "Optimize CLAUDE.md based on actual usage patterns. TRIGGER ON: 'optimize CLAUDE.md', 'improve CLAUDE.md', 'make CLAUDE.md better', 'trim CLAUDE.md', 'what is unused in CLAUDE.md', 'CLAUDE.md is too big', 'shrink CLAUDE.md', 'which docs are never read', 'CLAUDE.md usage', 'optimize context'. Analyzes which sections, docs, and commands Claude actually uses and recommends removals, compressions, and additions."
---

# optimize-claudemd — Optimize CLAUDE.md Based on Usage

You are the optimize-claudemd skill. You analyze how Claude actually uses the CLAUDE.md file — which sections are referenced, which docs are read, which commands are run — and recommend optimizations to maximize the value of every byte.

## When to trigger

- User asks to optimize, improve, trim, or shrink CLAUDE.md
- User asks what's unused or which docs are never read
- User says CLAUDE.md is too big or wants to improve context quality
- After significant project evolution (new features, removed docs)
- Health score shows CLAUDE.md-related deductions

**DO NOT trigger on:** general CLAUDE.md questions (use explain-state), initial CLAUDE.md generation (use bootstrap), or manual CLAUDE.md editing.

## Prerequisites

- Usage tracking must be enabled (`memory/claudemd-usage.json` must exist)
- At least 10 sessions of tracked data (override with `--force`)
- CLAUDE.md must have nyann markers (`<!-- nyann:start -->` / `<!-- nyann:end -->`)

If tracking is not enabled, offer to enable it: create `memory/claudemd-usage.json` with the empty template, then explain that data will accumulate over future sessions.

## Execution flow

### Phase 1: Analyze usage

1. Run `bin/analyze-claudemd-usage.sh --target .` to get the usage analysis.
2. Check `sufficient_data` — if false, explain how many more sessions are needed and offer `--force`.

### Phase 2: Present findings

3. Show the analysis summary:
   - Total sessions tracked
   - Section-by-section density table (section, bytes, references, density, verdict)
   - Unused docs (referenced in CLAUDE.md but never read by Claude)
   - Missing commands (frequently run but not documented)
   - Budget usage (bytes used / remaining)

4. For each recommendation, explain:
   - What to change (remove, compress, or add)
   - Why (density score, usage count)
   - Estimated byte savings

### Phase 3: Apply optimizations

5. Ask which recommendations to apply (all, specific ones, or none).
6. Run `bin/optimize-claudemd.sh --target . --profile <path> --dry-run` to preview.
7. Show the before/after diff.
8. On confirmation, run without `--dry-run`.
9. Report total bytes saved and new budget status.

### Phase 4: Next steps

10. Suggest running `/nyann:doctor` to see the health score impact.
11. If tracking was just enabled, explain that optimization will improve with more usage data.

## Key constraints

- Only modifies content within `<!-- nyann:start -->` / `<!-- nyann:end -->` markers
- Preserves all user content outside markers
- Respects 3KB soft budget and 8KB hard cap
- Never removes sections without showing the user what will be removed
- Compression is advisory — the skill shows what could be shortened but the actual rewrite is done by the LLM, not the bash script

## When to hand off

- "Regenerate CLAUDE.md from scratch" → `gen-claudemd` skill (full
  regeneration from profile + stack, not usage-driven pruning).
- "Check repo health" → `doctor` skill.
- "What does nyann see here?" → `explain-state` skill.
