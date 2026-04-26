---
name: nyann:record-decision
description: >
  Append a new MADR-formatted ADR to docs/decisions with an auto-incremented
  number.
arguments:
  - name: title
    description: "Imperative headline (e.g. 'Use Postgres for the primary datastore'). Required."
    optional: false
  - name: status
    description: "'proposed' (default) or 'accepted'."
    optional: true
  - name: dir
    description: "Target directory. Default 'docs/decisions'."
    optional: true
  - name: slug
    description: "Slug override (default: derived from title)."
    optional: true
  - name: dry-run
    description: Preview the target path without creating the file.
    optional: true
---

# /nyann:record-decision

Wraps `bin/record-decision.sh`. Flow:

1. Scan `<dir>` for existing `ADR-NNN-*.md` files; pick `N+1`.
2. Render `templates/docs/decisions/ADR-template.md` with number/title/status/date.
3. Write `<dir>/ADR-NNN-<slug>.md` (fails if path exists — pick a different slug).

Only MADR format supported in v1. See `skills/record-decision/SKILL.md` for the full confirmation flow and "don't auto-fill the body" guidance.
