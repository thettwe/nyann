---
name: explain-diff
description: >
  Translate a DriftReport JSON into a plain-English markdown narrative
  suitable for pasting into a PR description, chat thread, or bug
  report. Read-only template render — no LLM call, no filesystem
  mutation. Pairs with `doctor` via the `--explain` flag, or runs
  standalone against any DriftReport produced by `bin/compute-drift.sh`
  / `bin/retrofit.sh --json` / `bin/doctor.sh --json`.
  TRIGGER when the user says "explain the drift", "summarize doctor in
  plain English", "what does this drift report mean", "narrate the
  drift", "translate the drift report", "human-readable drift",
  "explain what nyann found", "make doctor output paste-friendly",
  "give me a drift summary for the PR", "/nyann:explain-diff".
  Do NOT trigger on "what's drifted" alone — that's `doctor` /
  `retrofit --report-only` (which produce the raw structured report
  this skill consumes). Do NOT trigger on "fix the drift" — that's
  `retrofit`.
arguments:
  - name: file
    description: Path to a DriftReport JSON file. Use `-` to read from stdin.
  - name: format
    description: Output format — `markdown` (default, human-readable) or `json` (DriftNarrative shape per schemas/drift-narrative.schema.json).
    optional: true
  - name: with-health
    description: Embed a health score (0-100) in the narrative header. Optional.
    optional: true
  - name: with-trend
    description: Embed a signed trend delta in the narrative header (e.g. `-8` for a 8-point regression). Optional.
    optional: true
---

# explain-diff

Read-only template render. Wraps `bin/explain-diff.sh`.

## When to trigger

- User has a DriftReport (from doctor / retrofit / compute-drift) and wants prose.
- User wants to paste a doctor summary into a PR body or chat without sharing raw JSON.
- User explicitly asks for "the drift in plain English".

## When NOT to trigger

- User is asking "is this repo healthy" → that's `doctor` (which can chain into this via `--explain`).
- User wants to mutate / fix → that's `retrofit`.
- User wants LLM-polished output → this skill is template-only by design (no LLM). If the user wants prose with more nuance, suggest reading the markdown output and editing by hand.

## Invocation

Three call shapes:

**1. Direct: file path**
```
bin/explain-diff.sh --file path/to/drift.json
```

**2. Pipe from a producer**
```
bin/compute-drift.sh --target . --profile default | bin/explain-diff.sh -
```

**3. Via doctor (recommended path)**
```
bin/doctor.sh --target . --profile default --explain
```

`doctor --explain` is preferred because it also forwards the computed health score and trend delta into the narrative header line — the same numbers text-mode shows at the foot of its output.

`--explain` is mutually exclusive with `--json` on doctor; if both are passed, doctor dies with a clear error.

## Output shape

**Markdown (default)** — three sections:

1. **Header** — target + profile + (optional) health score + trend
2. **What's drifted** — one bullet per drift category, ordered by severity. Each bullet has a lead phrase (`Action required:`, `Worth fixing:`, `Drifted:`, `Minor:`) and up to 5 concrete items. If a category has more than 5 items, an "...and N more" line appears.
3. **What you can do** — ordered action items that map to nyann skills (`nyann:retrofit`, `nyann:optimize-claudemd`, etc.)

**JSON (`--format json`)** — the DriftNarrative shape (`schemas/drift-narrative.schema.json`). Useful for chat-bot integrations or custom renderers that want the same source-of-truth without re-parsing the prose.

## Severity → lead-phrase mapping

| Severity | Lead | Sources |
|---|---|---|
| critical | "Action required:" | `missing[]`, broken links, `claude_md=error` |
| high | "Worth fixing:" | `misconfigured[]`, `claude_md=warn` / `absent`, subsystem errors |
| medium | "Drifted:" | `orphans`, staleness, `misplaced[]` |
| low | "Minor:" | non-compliant history (informational; nyann doesn't rewrite history) |
| info | (suppressed in markdown) | reserved for downstream filtering via the JSON shape |

The mapping is intentionally fixed (no profile-level override) so a narrative pasted into a PR reads the same regardless of which profile produced the underlying report.

## Reading the output back to the user

When the user asks for "the drift in plain English":

- Print the markdown block as-is. It's already formatted for human consumption.
- If the user asks for a "one-line summary" instead, count the `## What's drifted` bullets — the section count IS the summary number. E.g. "3 categories drifted: hooks (critical), claude_md (high), history (informational)."
- If the user asks "should I worry about Minor items" → no, those are CC-style informational checks; nyann doesn't rewrite history.
- If the report is clean (no `## What's drifted` section appears), the narrative says so explicitly — don't editorialise.

## Limits

- Template-only. No LLM smoothing — accept slightly mechanical phrasing as the cost of offline-safe rendering.
- Per-section items capped at 5 in the markdown output; the full list is in the JSON shape if a consumer needs it.
- Health score / trend are optional — if the caller doesn't supply them, the score line is suppressed (not faked to zero).
