---
name: doctor
description: >
  Run a read-only hygiene + documentation audit on the current repo.
  TRIGGER when the user says "is this repo healthy", "check hygiene",
  "audit this repo" (when they mean inspect, not remediate), "what's
  drifted", "run doctor", "run a health check", "audit docs", "check
  for doc drift", "what's broken in this project", "are the hooks
  still installed", "/nyann:doctor".
  Do NOT trigger on "fix this repo" / "remediate" / "bring it into
  compliance" — those are retrofit (audit + fix). doctor
  reports, never writes. Do NOT trigger on "what does this repo do"
  (that's a docs pointer, not a hygiene audit).
---

# doctor

Read-only audit. Never mutates the filesystem. Wraps
`bin/doctor.sh`, which internally runs `bin/retrofit.sh --report-only`.

## 1. Resolve the profile

`doctor.sh` requires `--profile <name>`. The skill's job is to pick the
right one without pestering the user:

1. Look for a `.nyann/profile` or equivalent profile hint in the repo.
2. If the repo's CLAUDE.md declares an active profile, use that.
3. If neither exists, ask the user which profile to audit against
   (`default`, `nextjs-prototype`, `python-cli`, or any user/team profile
   they've installed). Don't silently pick `default` — the audit is
   only meaningful against an intended baseline.

## 2. Invoke

```
bin/doctor.sh --target <cwd> --profile <name> [--json]
```

`--profile` takes a **bare profile name** (e.g. `python-cli`, `nextjs-prototype`),
not a filesystem path. The script resolves the name to the profile JSON internally.

Pass `--json` when the user says "machine-readable", "as JSON",
"pipe this", or similar — otherwise emit the human-readable report.

## 3. Interpret the exit code

| Code | Meaning | What to tell the user |
|---|---|---|
| 0 | clean | "No drift. Hygiene and docs look healthy." |
| 4 | warnings only | "Not failing, but some things have drifted. Here's the list." Offer to remediate via `retrofit`. |
| 5 | critical | "Missing required files or broken internal links. Run `retrofit` to fix." |

## 4. Sections in the report

The output has five blocks. When the user asks "what does each section
mean?", explain in terms of the repo, not nyann internals:

- **MISSING:** files the profile expects but the repo lacks (e.g. no
  `.husky/pre-commit` when the profile declares husky hooks).
- **MISCONFIGURED:** files present but content doesn't match (e.g. a
  `.husky/pre-commit` exists but doesn't actually run the expected
  linter).
- **NON-COMPLIANT HISTORY:** last N commit subjects that don't match
  Conventional Commits. Informational — nyann never rewrites history.
- **DOCUMENTATION:** CLAUDE.md size vs budget, internal link resolution,
  MCP link reachability (when MCP connectors are available), and orphan files under `docs/` / `memory/`.
- **GITHUB PROTECTION:** branch protection per strategy, tag-protection
  rulesets (when `.github.tag_protection_pattern` is declared in the
  profile), CODEOWNERS-required gate (when a CODEOWNERS file exists
  or `.github.require_code_owner_reviews=true`), and repo-security
  settings (Dependabot, secret scanning, push protection, code
  scanning). Soft-skips when `gh` is missing or unauthenticated.
  Driven by `bin/gh-integration.sh --check` under the hood. Critical
  drift here bumps the exit code to 5; warn drift bumps it to 4.

The protection block respects nyann's gh-best-effort invariant — it
never prompts for credentials and never blocks the audit. When `gh`
isn't reachable, the section reports `skipped` and contributes no
drift to the exit code.

## 5. Surface health trend (when available)

After showing the audit report, check whether `memory/health.json`
exists in the target repo. If it does:

1. Run `bin/health-trend.sh --target <cwd> --last 10`.
2. Show the sparkline and summary: "Health trend: ▃▄▅▆▇ — 72→85 over
   last 10 checks (↑ improving)."
3. If any `category_deltas` show worsening (delta < 0 in the breakdown),
   call them out: "⚠ `missing` got worse (−3 over the window)."
4. If the trend direction is `down`, suggest: "Score is declining — run
   `/nyann:retrofit` to address the drift."

If `memory/health.json` doesn't exist, skip silently — don't suggest
creating it. The persist step happens automatically via `doctor.sh`.

## 6. What to do after

- **User asks to fix drift** → hand off to `retrofit` ("fix this repo's
  drift"). Do not attempt to fix anything from inside the doctor skill.
- **User asks "why is this missing?"** → read back the profile's
  expectation for that item; don't guess.
- **User says "ignore warnings, they're false positives"** → there's
  no silencing mechanism inside doctor itself. If it's a recurring
  false positive, the profile or the repo's `.nyann-ignore`-equivalent
  is the right lever (future work, not today).

## When to hand off

- "Fix it" / "remediate" / "bring into compliance" → `retrofit`.
- "Why is this profile the active one?" → `inspect-profile` (if
  available) or read the profile JSON directly.
- "I want a different profile applied" → `retrofit` with the new
  profile name.
