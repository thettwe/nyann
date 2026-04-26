---
name: wait-for-pr-checks
description: >
  Poll a GitHub PR's checks until they all pass, any one fails, or a
  timeout is hit. Returns a structured outcome the caller can gate on.
  TRIGGER when the user says "wait for CI", "wait for the PR checks",
  "watch the PR", "is CI green yet", "babysit this PR's checks",
  "block until checks pass", "/nyann:wait-for-pr-checks".
  Do NOT trigger on "what's the PR status" (that's a one-off
  `gh pr view` — no polling). Do NOT trigger on "merge this PR" —
  that's the action AFTER waiting; consider auto-merge via
  `/nyann:pr --auto-merge` instead, which combines wait + merge.
---

# wait-for-pr-checks

Wraps `bin/wait-for-pr-checks.sh`. Poll-based; uses `gh pr checks
<num>` under the hood. The script is the same one `release.sh` will
soon gate the tag step on, so the contract is shared.

## 1. Resolve the PR number

The script auto-resolves from the current branch via `gh pr view`,
so the most common invocation is:

```
bin/wait-for-pr-checks.sh --target <cwd>
```

Pass `--pr <number>` when watching a PR you don't have checked out.

## 2. Tune timeout and cadence

Defaults:
- `--timeout 1800` (30 minutes)
- `--interval 30` (poll every 30 seconds)

Bump timeout for slow CI matrices ("integration tests take 90 min"
→ `--timeout 7200`). Drop interval for snappy local CI ("we Just
hit go" → `--interval 10`). Don't go below 10 seconds — gh API
rate limits start to bite.

## 3. Interpret the outcome

The script emits a `PRChecksResult` JSON. Branch on `.outcome`:

| Outcome | Meaning | What the user should do |
|---|---|---|
| `pass` | every check completed with a passing conclusion | proceed with the gated action (merge, tag, deploy) |
| `no-checks` | PR has no checks attached | proceed; treat as pass |
| `fail` | at least one check failed (loop bailed early) | open the linked workflow; don't proceed |
| `timeout` | deadline reached, some still in_progress | retry with a longer timeout, or investigate slow runners |
| `skipped` | gh missing/unauthenticated, or PR couldn't be resolved | tell the user; can't proceed |

Exit code mirrors the outcome: 0 for pass / no-checks / skipped, 3
for fail / timeout — caller scripts can gate on `$?`.

## 4. Combining with merge

This skill only waits. To wait-then-merge in one step, use
`/nyann:pr --auto-merge` — it sets up GitHub's native auto-merge
(which already handles "wait for required checks") instead of
polling client-side. Reserve this skill for cases where the user
wants the wait surfaced explicitly (release runs, manual gating).

## When to hand off

- "Merge it for me when CI passes" → `/nyann:pr --auto-merge`
  (server-side; doesn't tie up your terminal).
- "I just want the current status, don't wait" → `gh pr checks`
  directly; no polling needed.
- "Why did check X fail?" → `gh run view <run-id> --log-failed`;
  this skill only reports outcomes, not log contents.
