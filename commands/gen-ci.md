---
name: nyann:gen-ci
description: >
  Generate a GitHub Actions CI workflow (.github/workflows/ci.yml) from the
  project's nyann profile and detected stack. Produces lint, typecheck, and
  test jobs matching the hook configuration.
arguments:
  - name: profile
    description: Profile name to use. If omitted, resolves from preferences or CLAUDE.md markers.
    optional: true
  - name: dry-run
    description: Preview the workflow without writing it.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:gen-ci

Run the `gen-ci` skill (see `skills/gen-ci/SKILL.md`):

1. Detect the stack with `bin/detect-stack.sh`.
2. Resolve the active profile (argument → preferences → CLAUDE.md → default).
3. Generate the CI workflow via `bin/gen-ci.sh`.
4. Preview and confirm before writing.

Exit codes:
- `0` — workflow generated successfully
- `1` — error (missing template, invalid profile, etc.)

See also:
- `/nyann:gen-templates` — generate PR and issue templates
- `/nyann:bootstrap` — full project setup including CI
- `/nyann:doctor` — audit repo health
