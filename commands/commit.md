---
name: nyann:commit
description: >
  Generate a Conventional Commits message from the staged diff and commit
  after confirmation. Same flow as the natural-language `commit` skill —
  dispatches here so users who prefer explicit slash commands can bypass
  intent detection.
---

# /nyann:commit

Invokes the `commit` skill (`skills/commit/SKILL.md`) directly.

Happy path:

1. `bin/commit.sh --target <cwd>` — gather staged-diff context + detect
   the active commit convention.
2. Generate a message using `skills/commit/references/conventional-commits.md`
   as the authoritative rule set.
3. Preview to the user; they answer yes / edit / abort.
4. `bin/try-commit.sh` — run `git commit`; parse structured result.
5. On `result: rejected` for `stage: commit-msg`, regenerate with the
   hook's reason folded in. Cap at 2 retries.

## Flags

- `--edit-message`  don't commit automatically; show the message and
  let the user tweak it before commit.
- `--amend`         amend the previous commit instead of creating a new
  one (skill validates there's no remote history to worry about).
- `--no-retry`      skip the retry loop on hook rejection (surface
  immediately). Useful for CI.

## When not to trigger

- The user is on `main` / `master` — warn about the block-main hook and
  route through `/nyann:branch` first.
- Nothing staged — the skill will guide staging; don't call `git add -A`
  for them.

See also: `/nyann:branch`, `/nyann:bootstrap`, `/nyann:doctor`.
