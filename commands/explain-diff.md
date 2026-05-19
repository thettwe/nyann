---
name: nyann:explain-diff
description: >
  Translate a DriftReport JSON (from doctor / retrofit / compute-drift)
  into a plain-English markdown narrative. Read-only template render
  with no LLM call — produces paste-friendly output for PR bodies,
  chat threads, or bug reports.
arguments:
  - name: file
    description: Path to a DriftReport JSON. Use `-` for stdin.
  - name: format
    description: Output format — `markdown` (default) or `json` (DriftNarrative shape).
    optional: true
  - name: with-health
    description: Embed a health score (0-100) in the header.
    optional: true
  - name: with-trend
    description: Embed a signed trend delta in the header (e.g. `-8` for a regression).
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:explain-diff

Wraps `bin/explain-diff.sh`. Read-only. Renders a DriftReport into
markdown (default) or DriftNarrative JSON (`--format json`).

Pairs with `doctor`: prefer `bin/doctor.sh --explain` over piping when
both are available, since doctor forwards the computed health score
and trend delta into the narrative header.

See `skills/explain-diff/SKILL.md` for severity mapping, output
shape, and when to read the output back to the user.
