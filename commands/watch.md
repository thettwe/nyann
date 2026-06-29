---
name: nyann:watch
description: >
  Start (or stop) a CI sentinel for the current repo's open PRs — a
  one-shot foreground poll by default, or a supervised background daemon
  with --daemon. Also manage a multi-repo watch-list and poll every
  watched repo at once. Notifications surface in your next session via the
  session-start hook.
arguments:
  - name: pr
    description: Optional PR number to watch (default - all open PRs)
    optional: true
  - name: daemon
    description: >
      Pass --daemon to start a supervised background sentinel (launchd /
      systemd / nohup) that survives the session and self-terminates at
      --max-runtime (default 8h). Opt-in; confirm before starting.
    optional: true
  - name: stop
    description: Pass --stop to stop any running sentinel (one-shot or daemon) for this repo.
    optional: true
  - name: add
    description: Add <owner/repo> to the multi-repo watch-list (idempotent; pair with --pr).
    optional: true
  - name: remove
    description: Remove <owner/repo> from the multi-repo watch-list.
    optional: true
  - name: list
    description: Print the multi-repo watch-list.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/watch/SKILL.md` for the full flow.


# /nyann:watch

Wraps `bin/ci-sentinel.sh` (one-shot), `bin/sentinel-daemon.sh`
(supervised background daemon), and `bin/sentinel-aggregate.sh`
(multi-repo watch-list). Default: polls one or all open PRs once per
call, writing a Notification entry whenever a check status or review
status transitions. With `--daemon` (opt-in), starts a launchd / systemd
/ nohup-supervised loop that survives the session and self-caps at
`--max-runtime` (8h). `--stop` halts either mode.

For watching PRs across several repos, `--add`/`--remove`/`--list`
manage a watch-list at `~/.claude/nyann/watch-list.json`, and the
aggregate scheduler (`sentinel-aggregate.sh --poll`) polls every watched
repo under one globally rate-limit-aware loop. Read the merged,
repo-tagged view across all watched repos with
`bin/read-notifications.sh --all`. See `skills/watch/SKILL.md` Step 4.

Surfaces queued notifications via `bin/read-notifications.sh` on the next
session-start hook fire.
