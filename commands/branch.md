---
name: nyann:branch
description: >
  Create a strategy-compliant git branch. Same flow as the natural-language
  `new-branch` skill — dispatches here when users prefer explicit slash
  commands. Accepts positional args for purpose + slug so
  `/nyann:branch feature login` works directly without the skill having to
  parse phrasing.
arguments:
  - name: purpose
    description: feature | bugfix | release | hotfix
    optional: false
  - name: slug-or-version
    description: The branch slug (feature/bugfix/hotfix) or version string (release).
    optional: false
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:branch

Invokes the `new-branch` skill (`skills/new-branch/SKILL.md`).

## Positional usage

```
/nyann:branch feature login
/nyann:branch bugfix checkout-modal
/nyann:branch release 1.2.0
/nyann:branch hotfix auth-header
```

The skill decides whether the second arg is `--slug` or `--version`
based on the active profile's `branch_name_patterns[<purpose>]`.

## Orchestrator

Under the hood this calls:

```
bin/new-branch.sh \
  --target <cwd> \
  --profile <active-profile-name> \
  --purpose <purpose> \
  [--slug <slug> | --version <version>] \
  --checkout
```

Exit-code handling lives in `skills/new-branch/SKILL.md`.

## When not to trigger

- The repo hasn't been bootstrapped (no active profile) — run
  `/nyann:bootstrap` first.
- The user wanted to switch to an existing branch (`git checkout`) —
  that's not this command's job.

See also: `/nyann:commit`, `/nyann:bootstrap`, `/nyann:doctor`.
