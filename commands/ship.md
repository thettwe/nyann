---
name: nyann:ship
description: >
  Open a GitHub pull request AND merge it in one step. Default uses
  GitHub's native auto-merge (returns immediately with outcome:"queued");
  `--client-side` polls for green CI in the foreground then runs
  `gh pr merge`. Requires `gh` installed + authed.
arguments:
  - name: client-side
    description: Poll wait-for-pr-checks in the foreground and merge when green, instead of GitHub auto-merge. Use when auto-merge isn't enabled on the repo.
    optional: true
  - name: merge-strategy
    description: squash | rebase | merge. Default squash.
    optional: true
  - name: draft
    description: Open the PR as a draft. Rarely useful with ship — auto-merge waits for ready-for-review.
    optional: true
  - name: base
    description: Target base branch. Defaults to upstream / origin HEAD / `main`.
    optional: true
  - name: timeout
    description: Client-side mode only — seconds to wait for CI before bailing. Default 1800 (30 min).
    optional: true
  - name: interval
    description: Client-side mode only — seconds between PR-check polls. Default 30. Don't go below 10.
    optional: true
  - name: allow-no-checks
    description: Client-side mode only — opt out of the no-checks gate. Without this flag, the script refuses to merge a PR with zero checks attached (almost always a "workflows haven't attached yet" race after a fresh PR). Pass only for repos that genuinely run no PR-side CI.
    optional: true
---

# /nyann:ship

Wraps `bin/ship.sh`. Combines `bin/pr.sh` create + (auto-merge OR
`bin/wait-for-pr-checks.sh` + `gh pr merge --delete-branch`) into one
invocation that emits a ShipResult JSON
(`schemas/ship-result.schema.json`).

| Outcome | Mode | Exit | Meaning |
|---|---|---|---|
| `queued` | auto-merge | 0 | GitHub will merge server-side when checks + reviews pass |
| `shipped` | client-side | 0 | Wait completed, merge call succeeded, branch deleted |
| `ci-failed` | client-side | 3 | At least one check failed; loop bailed early |
| `ci-timeout` | client-side | 3 | Deadline hit, some still in progress |
| `merge-failed` | either | 3 | auto-merge couldn't be enabled, or `gh pr merge` failed |
| `pr-failed` | either | 3 | `bin/pr.sh` died before producing a URL |
| `skipped` | either | 0 | gh missing/unauthed (nothing created) |

## When to invoke

- "ship this PR" / "open and merge" → run this (auto-merge default).
- "ship it and block until merged" → run this with `--client-side`.
- "create the PR and auto-merge it on green CI" → run this (default).

## When NOT to invoke

- The user wants only the PR opened, not merged → `/nyann:pr`.
- The user wants to wait for CI but not merge → `/nyann:wait-for-pr-checks`.
- The PR already exists and they want to merge it → just
  `gh pr merge <num> --auto` directly; ship is for PR-creation + merge.
- The user wants to tag a release after merge → `/nyann:release`
  (run after ship reports `shipped` or after the auto-merge lands).

See `skills/ship/SKILL.md` for the full title/body synthesis flow,
mode-selection guidance, and outcome interpretation.
