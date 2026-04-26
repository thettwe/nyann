---
name: nyann:gen-templates
description: >
  Generate GitHub PR and issue templates (.github/) from the project's
  nyann profile. PR template includes quality checklists matching hook
  configuration; issue templates provide structured bug reports and
  feature requests.
arguments:
  - name: profile
    description: Profile name to use. If omitted, resolves from preferences or CLAUDE.md markers.
    optional: true
  - name: force
    description: Overwrite existing templates.
    optional: true
---

# /nyann:gen-templates

Run the `gen-templates` skill (see `skills/gen-templates/SKILL.md`):

1. Resolve the active profile.
2. Generate PR and issue templates via `bin/gen-templates.sh`.
3. Preview and confirm before writing.

Exit codes:
- `0` — templates generated successfully
- `1` — error (missing template source, invalid profile, etc.)

See also:
- `/nyann:gen-ci` — generate CI workflow
- `/nyann:bootstrap` — full project setup
