---
name: nyann:doctor
description: >
  Run nyann's read-only hygiene + documentation audit on the current repo.
  Emits the same drift sections retrofit uses, but never offers remediation
  or writes to the filesystem. Use this on session start, in CI, or any time
  you want to sanity-check a repo without risking mutations.
arguments:
  - name: profile
    description: Profile name to compare against. Defaults to the repo's active profile (stored in CLAUDE.md / local state); the command errors if it cannot resolve one.
    optional: true
  - name: json
    description: If passed, emit the DriftReport as JSON on stdout (no human-readable rendering). Useful for piping into `jq`.
    optional: true
---

# /nyann:doctor

Wraps `bin/doctor.sh --target <cwd> --profile <name>`.

Output is a three-section drift report plus DOCUMENTATION and
GITHUB PROTECTION blocks:

```
MISSING:                  files the profile expects but the repo lacks
MISCONFIGURED:            files present but content short of expectations
NON-COMPLIANT HISTORY:    last N commit subjects that don't match Conventional
                          Commits (informational only — no rewrite offered)

DOCUMENTATION:
  ✓/⚠/✗ CLAUDE.md size against budget
  ✓/✗  internal link resolution
  ⚠    MCP links needing connector verification (skill-layer)
  ✓/⚠  orphan detector on docs/ + memory/

GITHUB PROTECTION:        (when gh is reachable; soft-skips otherwise)
  ✗ branches/<name>: required_reviews, required_checks, …
  ✗ tags: pattern_present, blocks_force_push, …
  ✗ codeowners: file-missing-but-required, file-present-but-gate-off
  ✗ security: dependabot_alerts, secret_scanning, …
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | clean — no drift |
| 4 | warnings only (misconfigured, non-compliant history, orphans, CLAUDE.md warn/absent, soft protection drift) |
| 5 | critical (missing hygiene files, broken internal links, CLAUDE.md hard-cap error, missing branch/tag protection on a strategy-declared branch) |

## When to invoke

- "is this project healthy?" / "check hygiene" / "audit docs" → run this.
- User asks to fix drift → this finishes, then dispatch to
  `/nyann:retrofit` for remediation. doctor never fixes.

## Flags the skill layer forwards

- `--profile <name>`  override the active profile for this run.
- `--json`            emit the DriftReport JSON; useful for scripting.

See also:
- `/nyann:retrofit` — the remediation path once drift is confirmed.
- `/nyann:bootstrap` — full setup from scratch.
