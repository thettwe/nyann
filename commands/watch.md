---
name: nyann:watch
description: >
  Start (or stop) a CI sentinel for the current repo's open PRs — a
  one-shot foreground poll by default, or a supervised background daemon
  with --daemon. Notifications surface in your next session via the
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
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/watch/SKILL.md` for the full flow.


# /nyann:watch

Wraps `bin/ci-sentinel.sh` (one-shot) and `bin/sentinel-daemon.sh`
(supervised background daemon). Default: polls one or all open PRs once
per call, writing a Notification entry whenever a check status or review
status transitions. With `--daemon` (opt-in), starts a launchd / systemd
/ nohup-supervised loop that survives the session and self-caps at
`--max-runtime` (8h). `--stop` halts either mode. Surfaces queued
notifications via `bin/read-notifications.sh` on the next session-start
hook fire.
