---
name: watch
description: >
  Start (or stop) the nyann CI sentinel for the current repo. The sentinel
  polls open PRs for state transitions (CI failure, approval, merge,
  branch staleness) and emits notifications the session-start hook
  surfaces on your next prompt.
  TRIGGER when the user says "watch this PR", "watch my PRs", "ping me
  when CI passes", "tell me when CI fails", "background watch",
  "keep watching after I close this", "run the sentinel in the background",
  "daemonize the watcher", "watch in the background",
  "/nyann:watch", "/nyann:watch --pr <N>", "/nyann:watch --daemon",
  "stop watching", "/nyann:watch --stop".
  Do NOT trigger on "wait for checks" — that is `/nyann:wait-for-pr-checks`
  (blocking poll). watch is fire-and-forget; wait-for-pr-checks blocks.
---

# watch

> **Plugin root:** `<plugin_root>/skills/watch/SKILL.md` — scripts live
> at `<plugin_root>/bin/ci-sentinel.sh`, `bin/sentinel-daemon.sh`, and
> `bin/read-notifications.sh`.

## Step 1: Resolve repo

Use `gh repo view --json nameWithOwner --jq .nameWithOwner` to get the
`<owner>/<repo>` slug for the current directory. If `gh` is missing or
the repo has no GitHub remote, tell the user to set one up and stop.

## Step 2: Start, stop, or list

If the user said "stop" / `--stop`, stop BOTH a one-shot poll and any
backgrounded daemon (the daemon stop tears down the supervisor unit too):
```
bash <plugin_root>/bin/sentinel-daemon.sh stop --repo <owner/repo>
```
For a single foreground poll cycle (default — fire-and-forget):
```
bash <plugin_root>/bin/ci-sentinel.sh --repo <owner/repo> [--pr <N>]
```
The sentinel is one-shot per invocation — each run polls the named PR(s)
once and writes notification entries to
`~/.claude/nyann/notifications/<repo-hash>.jsonl`.

### Backgrounded daemon (`--daemon`) — opt-in

Only when the user explicitly asks to keep watching after the session
ends (`--daemon`, "background watch", "keep watching after I close
this"), offer the supervised daemon. **Do not start it implicitly** — a
long-running background process is opt-in, mirroring the session-triage
hook-install precedent. Confirm first, then:
```
bash <plugin_root>/bin/sentinel-daemon.sh start --repo <owner/repo> [--pr <N>]
```
This launches `ci-sentinel.sh --daemon-loop` under a platform supervisor
(launchd on macOS, a systemd user unit on Linux, `nohup` fallback
otherwise) so it survives the terminal closing. It polls every interval,
backs off on `gh` failures, and self-terminates at `--max-runtime`
(default 8h) as an orphan backstop. Starting is idempotent — a daemon
already running for the repo is left alone.

Report status (pid + supervisor + watched PRs; flags a stale daemon)
with:
```
bash <plugin_root>/bin/sentinel-daemon.sh status --repo <owner/repo>
```
`doctor` also surfaces any running/stale sentinel so it's never invisible.

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
