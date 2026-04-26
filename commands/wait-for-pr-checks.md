---
name: nyann:wait-for-pr-checks
description: >
  Poll a GitHub PR's checks until they all pass, any one fails, or a
  timeout is hit. Returns a structured outcome the caller can gate on.
arguments:
  - name: pr
    description: PR number to watch. Defaults to the PR for the current branch (resolved via `gh pr view`).
    optional: true
  - name: timeout
    description: Seconds before the wait gives up with `outcome:"timeout"`. Default 1800 (30 min).
    optional: true
  - name: interval
    description: Seconds between polls. Default 30. Don't go below 10 — gh API rate limits start to bite.
    optional: true
---

# /nyann:wait-for-pr-checks

Wraps `bin/wait-for-pr-checks.sh`. Same gh-best-effort pattern as the
rest of the GitHub-touching scripts: never prompts for credentials,
soft-skips when gh is missing or unauthenticated.

| Outcome | Exit code | Meaning |
|---|---|---|
| `pass` | 0 | every check completed with a passing conclusion |
| `no-checks` | 0 | PR has no checks attached (treat as pass) |
| `skipped` | 0 | gh unreachable or PR couldn't be resolved |
| `fail` | 3 | at least one check failed; loop bailed early |
| `timeout` | 3 | deadline reached, some still in progress |

## When to invoke

- "wait for CI to finish on this PR" → run this.
- "block until checks are green before I merge" → run this, then
  merge on `outcome: "pass"`.
- "babysit the PR, ping me when it's done" → run this; the stderr
  log line emits per-poll progress.

## When NOT to invoke

- The user wants to merge immediately when checks pass — use
  `/nyann:pr --auto-merge` (server-side, doesn't tie up the terminal).
- The user just wants the current status snapshot — `gh pr checks
  <num>` directly.

See also:
- `/nyann:pr --auto-merge` — combines wait + merge via GitHub's
  native auto-merge feature.
- `/nyann:release` — uses this script to gate the tag step on green
  checks (when invoked with `--wait-for-checks`).
