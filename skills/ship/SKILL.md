---
name: ship
description: >
  Open a PR and merge it in one step — combines `bin/pr.sh` create with
  `bin/wait-for-pr-checks.sh` polling and `gh pr merge`. Default mode
  enables GitHub's native auto-merge so the terminal returns
  immediately; `--client-side` polls in the foreground and merges when
  CI goes green.
  TRIGGER when the user says "ship this PR", "ship it", "open and merge",
  "PR and merge", "create PR and auto-merge it", "wait for CI then merge",
  "block until merged", "/nyann:ship".
  Do NOT trigger on "open a PR" alone (no merge intent) — that's the
  `pr` skill. Do NOT trigger on "merge this existing PR #N" — ship is
  PR-creation + merge, not standalone merge of an already-open PR.
  Do NOT trigger on "release X.Y.Z" — that's the `release` skill, which
  tags a merged commit rather than creating one.
---

# ship

Wraps `bin/ship.sh`. The script composes `bin/pr.sh` (PR creation),
`bin/wait-for-pr-checks.sh` (poll), and `gh pr merge` (merge) into a
single ShipResult. The output schema is at
`schemas/ship-result.schema.json`.

## 0. Drift check (quick, non-blocking)

Run `bin/session-check.sh` before starting. If it produces output,
show the one-line drift summary to the user as an informational note
(e.g. "Heads up: nyann detected drift vs your profile. Run
`/nyann:retrofit` when you get a chance."). Do not block the ship
flow — this is a nudge, not a gate.

## 1. Pick the mode up front

Two modes, decided at invocation. They have very different terminal
behavior, so confirm with the user when it isn't obvious which they
want.

| Mode | Default | Terminal behavior | Use when |
|---|---|---|---|
| `auto-merge` | yes | returns ~instantly with `outcome:"queued"` | repo allows auto-merge, user wants to walk away |
| `client-side` (`--client-side`) | opt-in | blocks until ship-or-fail | repo doesn't allow auto-merge, or user wants the wait surfaced |

If the user says "ship it and let me know when it's in" or "block
until merged", use `--client-side`. If they say "queue it for merge"
or "ship and I'll come back later", use the default.

When the user's intent doesn't clearly map to either mode, **you MUST
call the `AskUserQuestion` tool** (not plain text):

```json
{
  "questions": [
    {
      "question": "How should this PR be merged after CI passes?",
      "header": "Ship mode",
      "multiSelect": false,
      "options": [
        { "label": "Auto-merge (Recommended)", "description": "Returns immediately; GitHub merges when checks pass" },
        { "label": "Client-side", "description": "Blocks here until CI is green, then merges" }
      ]
    }
  ]
}
```

## 2. Pre-flight (same as `pr` skill)

- `bin/ship.sh` runs the same gh guard as `bin/pr.sh`. Skip records
  with reason `gh-not-installed` or `gh-not-authenticated` short-circuit
  before any PR is created. Relay these as-is.
- The current branch must not be `main`/`master`. The underlying
  `pr.sh` enforces this; if it dies, route the user to
  `/nyann:branch` first.
- Synthesize the title + body the same way the `pr` skill does:
  `bin/pr.sh --target <cwd> --context-only` first, then build a
  Conventional-Commits title and a Summary/Test-plan markdown body.

## 3. Confirm before shipping

Show the user the proposed title, body, and **mode** before invoking.

- **Auto-merge**: "Ship it via auto-merge? (returns immediately;
  GitHub merges when checks pass)"
- **Client-side**: "Block here while CI runs and merge when green?
  Default timeout is **30 minutes** (polling every **30 seconds**).
  Override with `--timeout` / `--interval` if your CI is slower."

Skip the confirmation only when the user said "just ship it" / "don't
ask, ship it now".

## 4. Invoke

```
bin/ship.sh \
  --target <cwd> \
  --title "<conventional-title>" \
  --body  "<markdown-body>" \
  [--base <branch>] \
  [--draft] \
  [--client-side] \
  [--merge-strategy squash|rebase|merge] \
  [--timeout <sec>] [--interval <sec>] \
  [--allow-no-checks]
```

`--draft` opens as draft (auto-merge will wait for ready-for-review +
checks; client-side mode merges as draft if you pass `--draft`, which
is rarely what you want). `--merge-strategy` defaults to `squash`;
respect the user's preference if they name a different one. `--timeout`
and `--interval` are forwarded to the wait phase in client-side mode
(defaults: 30 min / 30 s).

`--allow-no-checks` is a safety opt-out for client-side mode. By
default, the script refuses to merge when the waiter reports
`no-checks` — that outcome on a fresh PR almost always means
"workflows haven't attached yet" rather than "this repo has no PR
CI", so silently merging would defeat the gate. Pass
`--allow-no-checks` only when you know the repo runs no PR-side
checks (no GitHub Actions, no required reviews, etc.) and the empty
state is intentional. Auto-merge mode doesn't need this flag —
GitHub's server-side auto-merge already handles required-checks
state correctly.

## 5. Interpret the outcome

Branch on `.outcome`:

| Outcome | Mode | What happened | What the user should do |
|---|---|---|---|
| `queued` | auto-merge | GitHub's auto-merge enabled; merge happens server-side when checks + reviews pass | trust it, walk away |
| `shipped` | client-side | merge call succeeded after green CI | done; PR is merged + branch deleted |
| `ci-failed` | client-side | one or more checks failed OR the PR had no checks attached without `--allow-no-checks`; loop bailed | inspect `ci_failed_reason` in the JSON; for the no-checks case re-run with `--allow-no-checks` if the empty state is intentional, otherwise wait for workflows to attach and retry |
| `ci-timeout` | client-side | wait deadline hit, some still in_progress | retry with `--timeout` higher, or investigate runners |
| `merge-failed` | either | auto-merge couldn't be enabled (e.g. branch protection) or `gh pr merge` failed | inspect `merge_failed_reason`; common causes: required reviews missing, branch protection forbids the strategy |
| `pr-failed` | either | `bin/pr.sh` died before producing a URL | rerun `/nyann:pr` to surface the underlying error |
| `skipped` | either | gh missing/unauthed; nothing was created | tell the user; can't proceed |

The script always exits 0. Branch on the `.outcome` field in the
JSON to determine what happened.

## 6. Handling errors

- `merge-failed` with reason like "auto-merge is not allowed" → suggest
  retrying with `--client-side`, which polls then calls `gh pr merge`
  directly (works even when server-side auto-merge is disabled).
- `merge-failed` with reason like "required reviews" → relay verbatim;
  the user needs a reviewer to approve before merge can proceed.
- `ci-failed` → don't suggest re-running ship; route the user to fix
  the failing job first. Mention they can check it via
  `gh pr checks <num>` directly.

## When to hand off

- "Just open the PR" / "don't merge yet" → `pr` skill.
- "Wait for CI but don't merge" → `wait-for-pr-checks` skill.
- "Tag a release after merge" → `release` skill — invoke after ship
  reports `shipped` or after the auto-merge actually lands.
