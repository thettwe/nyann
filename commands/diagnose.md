---
name: nyann:diagnose
description: >
  Bundle a redacted support-grade snapshot of the current nyann state
  (state + drift + hooks + config + prereqs) for inclusion in a bug
  report.
arguments:
  - name: target
    description: Path to the repo to diagnose. Defaults to the current working directory.
    optional: true
  - name: profile
    description: Profile name to diagnose against. Defaults to the inferred / `default` profile.
    optional: true
  - name: user-root
    description: Override `~/.claude/nyann` (the location of `preferences.json` and team-source cache).
    optional: true
  - name: json
    description: Emit the machine-readable JSON bundle (default is a human-readable summary).
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:diagnose

Wraps `bin/diagnose.sh`. Read-only. Aggregates `explain-state`, `doctor --json`, redacted git config, installed hook contents, redacted nyann user-config, and `check-prereqs` into one paste-friendly bundle.

URL credentials are redacted via `nyann::redact_url` before any field reaches stdout. Output is safe to paste into a public GitHub issue.

See `skills/diagnose/SKILL.md` for trigger phrases and DISAMBIGUATION from `doctor`, `explain-state`, and `retrofit`.
