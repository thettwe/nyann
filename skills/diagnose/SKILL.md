---
name: diagnose
description: >
  Bundle a redacted, support-grade snapshot of the current nyann state
  for inclusion in a bug report or support request. Combines
  explain-state + doctor + git config (token-redacted) + installed hook
  contents + nyann user-config (token-redacted) + check-prereqs into a
  single JSON or human-readable summary.
  TRIGGER when the user says "nyann is broken", "nyann diagnose",
  "diagnose nyann", "diagnose this repo", "support bundle", "what's
  wrong with nyann", "help me file a bug report", "what should I
  include in a nyann bug report", "/nyann:diagnose".
  Do NOT trigger on "is this repo healthy" — that's `doctor` (read-only
  audit). Do NOT trigger on "what does nyann see here" — that's
  `explain-state` (lighter snapshot, no health, no hook contents). Do
  NOT trigger on "fix this repo" — that's `retrofit`.
---

# diagnose

Read-only support bundle. Aggregates everything a maintainer needs to reproduce or pinpoint a nyann bug into one paste-friendly output.

## When to trigger

- User reports nyann broke on their repo and wants to file a bug
- User asks for a "support bundle", "diagnostic dump", or wants to know what to include in an issue
- User says nyann is misbehaving and wants help collecting evidence

## What gets bundled

`bin/diagnose.sh` collects, in one structured JSON object:

- **`nyann_version`** — from `.claude-plugin/plugin.json`
- **`host`** — `uname -srm`, bash version, jq/git/gh versions
- **`repo`** — `bin/explain-state.sh --json` output (stack, profile, branching, hooks, CLAUDE.md, recent commits)
- **`health`** — `bin/doctor.sh --json` output (drift report + health score)
- **`git`** — `git config --list` lines + `git status --porcelain`, with embedded URL credentials redacted via `nyann::redact_url`
- **`hook_files`** — first 8 KB of `.git/hooks/pre-commit`, `.git/hooks/commit-msg`, `.husky/pre-commit`, `.husky/commit-msg`, `.pre-commit-config.yaml` (each `null` when absent)
- **`nyann_config`** — `~/.claude/nyann/preferences.json` + `team_profile_sources[]` with URLs redacted
- **`prereqs`** — `bin/check-prereqs.sh --json`

Every field flows through redaction. The bundle is safe to paste into a public GitHub issue.

## Execution flow

### Phase 1: Explain what diagnose collects

Tell the user: "I'll run `bin/diagnose.sh` against this repo. It collects state, drift, hooks, and configuration into one bundle. URL credentials and tokens are redacted before output."

### Phase 2: Run the bundle

Run `bin/diagnose.sh --target . --json` (default mode is human-readable; `--json` for the paste-into-issue version).

If the user wants to share publicly, suggest:
- Pipe to a file: `bin/diagnose.sh --target . --json > nyann-diagnose-$(date +%Y%m%d).json`
- OR use the human-readable mode (`bin/diagnose.sh --target .`) for a quick eyeball summary

### Phase 3: Surface the obvious problems

Before handing the bundle off, look at:
- `health.summary.broken_links` > 0 → user has broken internal links
- `health.summary.missing` > 0 → user has missing hygiene files
- `repo.claude_md.bytes` > 8192 → CLAUDE.md over the hard cap
- `prereqs[].status` of `missing` for any `kind: hard` → nyann lacks a required tool

Mention the obvious ones; the maintainer will look at the bundle for the rest.

### Phase 4: Where to file

Direct the user to the right surface:
- **Bug report:** <https://github.com/thettwe/nyann/issues/new>; paste the JSON bundle into a `<details>` block
- **Security issue:** see `SECURITY.md`; do NOT open a public issue

## Key constraints

- **Read-only.** Mirrors doctor's contract: never writes, never persists, never opens a network call beyond what `doctor --json` already does.
- **Redaction is the contract.** Any URL with embedded credentials passes through `nyann::redact_url` before emission. Tokens never reach stdout.
- **Truncated hook content (8 KB cap)** so a multi-MB hook script doesn't bloat the bundle.
- **Per-tier degradation:** if `gh` is missing, the bundle still emits with `host.gh = "missing"`. If `~/.claude/nyann/preferences.json` doesn't exist, `nyann_config = null`. If the target isn't a git repo, `git`, `health`, and `repo` are stub-empty but the bundle still emits.

## When to hand off

- "Fix the issues" / "remediate" → `retrofit` skill (targeted fixes)
  or `doctor` skill (audit first, then decide).
- "Just check health, not a full bundle" → `doctor` skill.
- "What does nyann see here?" → `explain-state` skill (lighter, no
  health or hook contents).
