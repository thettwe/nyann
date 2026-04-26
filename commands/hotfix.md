---
name: nyann:hotfix
description: >
  Create the branch topology for a patch release against a previously
  tagged version. Ensures `release/<major>.<minor>` exists from the
  source tag, then creates `hotfix/<slug>` off it. After this, the
  user commits the fix and runs `/nyann:release` from the hotfix branch.
arguments:
  - name: from
    description: Source tag (e.g. `v1.2.0`). Must exist locally — `git fetch --tags origin` first if needed.
    optional: false
  - name: slug
    description: Slug for the hotfix branch name. Must match `^[a-z0-9][a-z0-9-]*$`. Final branch will be `hotfix/<slug>`.
    optional: false
  - name: release-branch
    description: Override the auto-derived release branch. Default is `release/<major>.<minor>` from the source tag.
    optional: true
  - name: checkout
    description: Switch to the hotfix branch after creation. Default is to leave the user on their current branch (the JSON's next_steps tells them how to switch).
    optional: true
---

# /nyann:hotfix

Wraps `bin/hotfix.sh`. Minimal-state setup: this command creates
branches, the user commits the fix, then `/nyann:release` does the
tag + push.

## Safety

- Refuses to overwrite an existing `hotfix/<slug>` branch (no silent
  stomp of in-progress work).
- Reuses an existing `release/<major>.<minor>` branch idempotently
  (multiple patches on the same minor live on the same branch).
- Source tag must exist locally — explicit error if missing, with a
  hint to `git fetch --tags origin`.

## Output

A `HotfixResult` JSON. Most useful field is `next_steps[]` — concrete
commands the user runs to take the hotfix from setup to shipped:

1. (Optional) `git checkout hotfix/<slug>` — only when --checkout
   wasn't passed.
2. Make the fix, commit it.
3. `git checkout release/<m>.<n> && git merge --no-ff hotfix/<slug>`
4. `/nyann:release --version <suggested-patch> --push` (from the
   release branch — release.sh tags HEAD).

## When to invoke

- "I need to patch v1.2.0" → run this.
- "Backport this fix to the previous minor" → run this against the
  most recent tag on that minor.
- "We have a security issue in the v1 line" → run this; release.sh's
  prerelease detection handles `-rc` suffixes if you want a pre-release
  patch.

## When NOT to invoke

- The user just wants a feature branch (no release-branch lineage):
  `/nyann:branch fix <slug>`.
- The user already has the hotfix branch ready and committed: merge
  into the release branch first (`git checkout <release> && git
  merge --no-ff <hotfix>`), then `/nyann:release --version <patch>`.

See also:
- `/nyann:release` — the tag + push step that runs after this.
- `/nyann:branch` — for non-hotfix branches (no tag lineage).
- `/nyann:cleanup-branches` — prune `hotfix/<slug>` after the
  release has merged back to main.
