---
name: watch
description: >
  Start (or stop) the nyann CI sentinel for the current repo, OR manage a
  multi-repo watch-list and poll all watched repos at once. The sentinel
  polls open PRs for state transitions (CI failure, approval, merge,
  branch staleness) and emits notifications the session-start hook
  surfaces on your next prompt.
  TRIGGER when the user says "watch this PR", "watch my PRs", "ping me
  when CI passes", "tell me when CI fails", "background watch",
  "keep watching after I close this", "run the sentinel in the background",
  "daemonize the watcher", "watch in the background",
  "/nyann:watch", "/nyann:watch --pr <N>", "/nyann:watch --daemon",
  "stop watching", "/nyann:watch --stop".
  ALSO TRIGGER for multi-repo aggregation: "watch all my repos", "watch
  across repos", "add a repo to my watch list", "add <owner/repo> to watch",
  "remove <owner/repo> from watch", "list watched repos", "what's new across
  all my repos", "poll every repo I'm watching", "/nyann:watch --add",
  "/nyann:watch --remove", "/nyann:watch --list".
  Do NOT trigger on "wait for checks" — that is `/nyann:wait-for-pr-checks`
  (blocking poll). watch is fire-and-forget; wait-for-pr-checks blocks.
---

# watch

> **Plugin root:** `<plugin_root>/skills/watch/SKILL.md` — scripts live
> at `<plugin_root>/bin/ci-sentinel.sh`, `bin/sentinel-daemon.sh`,
> `bin/sentinel-aggregate.sh`, and `bin/read-notifications.sh`.

Two modes:
- **Single repo** (Steps 1–3): poll the current repo's PRs directly —
  one-shot, or as a supervised background daemon (`--daemon`).
- **Multi-repo** (Step 4): keep a watch-list of repos and poll them all
  under one rate-limit-aware scheduler. Use this when the user watches PRs
  across several repos and wants one merged view.

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

## Step 4: Multi-repo watch-list (aggregation)

When the user watches PRs across several repos, manage a watch-list and
poll them all at once instead of running the single-repo flow per repo.
The watch-list lives at `~/.claude/nyann/watch-list.json` (an array of
`{repo, prs?}`); manage it via `bin/sentinel-aggregate.sh`, because one
scheduler must own the GitHub rate budget for all repos.

Add / remove / list watched repos:
```
bash <plugin_root>/bin/sentinel-aggregate.sh --add <owner/repo> [--pr <N>]
bash <plugin_root>/bin/sentinel-aggregate.sh --remove <owner/repo>
bash <plugin_root>/bin/sentinel-aggregate.sh --list
```
`--add` is idempotent (re-adding never duplicates; `--pr` merges into the
repo's PR set), so you can run it freely. Malformed slugs are rejected.

Poll every watched repo in one cycle:
```
bash <plugin_root>/bin/sentinel-aggregate.sh --poll
```
This runs `ci-sentinel.sh` once per repo, but a single scheduler tracks the
GitHub core rate budget and backs off **globally** (adaptive interval, all
repos) when the budget runs low — because N repos × M PRs would otherwise
blow the 5000/hr ceiling. It prints a scheduler-summary JSON
(`current_interval` tells a supervising daemon how long to sleep next).

To keep the whole watch-list polling **in the background** after the session
ends (same opt-in confirm as the single-repo daemon — a long-running process
is never started implicitly), supervise the aggregate loop via the daemon
manager:
```
bash <plugin_root>/bin/sentinel-daemon.sh start  --aggregate
bash <plugin_root>/bin/sentinel-daemon.sh status --aggregate
bash <plugin_root>/bin/sentinel-daemon.sh stop   --aggregate
```
This launches `sentinel-aggregate.sh --daemon-loop` under launchd / systemd /
nohup, sleeping each cycle's `current_interval` and self-capping at
`--max-runtime` (8h). One aggregate daemon runs per user; `doctor` surfaces it
alongside any per-repo daemons.

Read the unified, repo-tagged view across every watched repo:
```
bash <plugin_root>/bin/read-notifications.sh --all
```
Each entry is tagged with `context.repo` so you can say which repo it came
from. `--all` drains every watched queue (use `--peek` to leave them
intact). Render grouped by repo:

```
[nyann] 3 notifications across 2 repos:
  acme/api:
    - PR #42: CI failed (2h ago)
  acme/web:
    - PR #7: approved (15m ago)
    - PR #9: merged into main (1h ago)
```

## When to hand off

- "Wait until CI passes" → `wait-for-pr-checks` (blocking).
- "Merge the PR when CI passes" → `ship` (PR + merge in one step).
