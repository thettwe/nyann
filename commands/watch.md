---
name: nyann:watch
description: >
  Start (or stop) a one-shot CI sentinel poll for the current repo's
  open PRs. Notifications surface in your next session via the
  session-start hook.
arguments:
  - name: pr
    description: Optional PR number to watch (default - all open PRs)
    optional: true
  - name: stop
    description: Pass --stop to kill any running sentinel for this repo.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/watch/SKILL.md` for the full flow.


# /nyann:watch

Wraps `bin/ci-sentinel.sh`. Polls one or all open PRs once per call;
writes a Notification entry whenever a check status or review status
transitions. Surfaces queued notifications via `bin/read-notifications.sh`
on the next session-start hook fire.
