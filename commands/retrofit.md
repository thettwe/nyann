---
name: nyann:retrofit
description: >
  Audit an existing repo against a profile and fix what's drifted. Unlike
  doctor (read-only), retrofit detects missing hooks, misconfigured gitignore,
  documentation gaps, and non-compliant history, then offers to remediate via
  bootstrap. Idempotent — safe to re-run.
arguments:
  - name: profile
    description: Profile name to audit against. If omitted, resolves from CLAUDE.md markers or asks the user.
    optional: true
  - name: json
    description: If passed, emit the DriftReport as JSON without human-readable rendering or remediation offer.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:retrofit

Wraps `bin/retrofit.sh --target <cwd> --profile <name>`.

Audit + remediation flow for existing repos with partial or drifted setups:

```
detect stack → load profile → compute drift → render report → offer fix
                                                                  ↓
                                              build plan → preview → bootstrap
```

Output is the same four-section drift report as doctor:

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
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | clean — no drift, nothing to fix |
| 4 | warnings only (misconfigured, non-compliant history, orphans, CLAUDE.md warn/absent) |
| 5 | critical (missing hygiene files, broken internal links, CLAUDE.md hard-cap error) |

## When to invoke

- "fix this repo" / "retrofit this repo" / "bring into compliance" → run this.
- "my repo is half set up, finish it" / "fill in the gaps" → run this.
- After `/nyann:doctor` reports drift and user says "fix it" → run this.

## Flags the skill layer forwards

- `--profile <name>`  override profile resolution for this run.
- `--json`            emit DriftReport JSON; skips remediation offer.

See also:
- `/nyann:doctor` — read-only audit (same report, no remediation).
- `/nyann:bootstrap` — full setup from scratch.
