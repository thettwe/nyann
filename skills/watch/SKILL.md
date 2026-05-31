---
name: watch
description: >
  Start (or stop) the nyann CI sentinel for the current repo. The sentinel
  polls open PRs for state transitions (CI failure, approval, merge,
  branch staleness) and emits notifications the session-start hook
  surfaces on your next prompt.
  TRIGGER when the user says "watch this PR", "watch my PRs", "ping me
  when CI passes", "tell me when CI fails", "background watch",
  "/nyann:watch", "/nyann:watch --pr <N>", "stop watching", "/nyann:watch --stop".
  Do NOT trigger on "wait for checks" — that is `/nyann:wait-for-pr-checks`
  (blocking poll). watch is fire-and-forget; wait-for-pr-checks blocks.
---

# watch

> **Plugin root:** `<plugin_root>/skills/watch/SKILL.md` — scripts live
> at `<plugin_root>/bin/ci-sentinel.sh` and `bin/read-notifications.sh`.

## Step 1: Resolve repo

Use `gh repo view --json nameWithOwner --jq .nameWithOwner` to get the
`<owner>/<repo>` slug for the current directory. If `gh` is missing or
the repo has no GitHub remote, tell the user to set one up and stop.

## Step 2: Start, stop, or list

If the user said "stop" / `--stop`:
```
bash <plugin_root>/bin/ci-sentinel.sh --repo <owner/repo> --stop
```
Otherwise start a single poll cycle:
```
bash <plugin_root>/bin/ci-sentinel.sh --repo <owner/repo> [--pr <N>]
```

For backgrounded polling, wrap in `nohup` and a wait loop on the
caller's side. The sentinel itself is one-shot per invocation — each
run polls the named PR(s) once and writes notification entries to
`~/.claude/nyann/notifications/<repo-hash>.jsonl`.

## Step 3: Show outstanding notifications

After polling (or whenever the user asks "what's new on my PRs?"):
```
bash <plugin_root>/bin/read-notifications.sh --repo <owner/repo>
```
This reads all queued notifications and truncates the file. Use
`--peek` if you want to leave the queue intact.

Render the result as a short list:

```
[nyann] 2 notifications since last check:
  - PR #42: CI failed (2h ago)
  - PR #43: approved (15m ago)
```

## When to hand off

- "Wait until CI passes" → `wait-for-pr-checks` (blocking).
- "Merge the PR when CI passes" → `ship` (PR + merge in one step).
