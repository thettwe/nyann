---
name: hotfix
description: >
  Set up the branch topology for a patch release against a previously
  tagged version: ensures release/<major>.<minor> exists from the source
  tag, then creates hotfix/<slug> off it.
  TRIGGER when the user says "hotfix v1.0.0", "patch the release",
  "I need to fix something in the v2 line", "create a hotfix branch",
  "/nyann:hotfix". Match phrases like "fix this for the previous
  release" or "backport this fix to v1.0".
  Do NOT trigger on "fix this bug" without a target tag — that's a
  regular feature branch via `/nyann:branch fix <slug>`. Do NOT
  trigger on "release a hotfix" if the user already has the branch
  set up — they're after `/nyann:release` directly.
---

# hotfix

Wraps `bin/hotfix.sh`. Creates the two branches a patch-release
flow needs:

1. `release/<major>.<minor>` — long-lived, branched from the source
   tag. Idempotent: reused if it already exists. Future patches on
   the same minor go on the same branch.
2. `hotfix/<slug>` — short-lived, branched off the release branch.
   The user commits the actual fix here.

After this skill: the user makes the fix, commits, then runs
`/nyann:release` from the hotfix branch.

## 1. Resolve the source tag

Before invoking, confirm the source tag with the user:

- "I want to patch v1.2.0" → `--from v1.2.0`.
- "I want to fix something in the previous minor" → ask which tag
  exactly.
- If they said "patch the latest release" without naming a tag,
  list `git tag --sort=-v:refname | head -5` and ask.

## 2. Pick a slug

Ask: "what's the change?" Convert their answer to a slug:

- "Fix the broken auth callback" → `fix-auth-callback`
- "Patch the SQLi in the user-search endpoint" → `patch-sqli-user-search`

The script enforces lowercase + alphanumeric + hyphen; it'll reject
anything else.

## 3. Invoke

```
bin/hotfix.sh --target <cwd> --from <tag> --slug <slug> --checkout
```

`--checkout` switches to the hotfix branch immediately. Skip it
when the user has uncommitted work in the current branch (the
script will warn about a dirty tree if checkout fails — don't
let it half-finish).

## 4. Hand back the next-steps

The output JSON includes a `next_steps[]` array with the exact
commands to run next:

1. (skip if --checkout was used) `git checkout hotfix/<slug>`
2. Make the fix, commit it (use `/nyann:commit` for a
   Conventional Commits message).
3. Merge the hotfix into the release branch:
   `git checkout release/<m>.<n> && git merge --no-ff hotfix/<slug>`.
4. Run `/nyann:release --version <patch> --push` from the release
   branch. The script suggests the patch version (source-tag + 1 in
   the patch slot) — confirm with the user before passing it through.
   `release.sh` operates on the current branch (HEAD), so the merge
   step in (3) is what puts the right commits on the lineage that
   gets tagged.

## 5. After the release

- The release tag (e.g. `v1.2.4`) is added on `release/1.2`.
- The release branch should be merged back into `main` so the fix
  isn't lost on the next minor cut. nyann doesn't do this for the
  user; suggest `git checkout main && git merge --no-ff release/1.2 && git push`.
- Consider deleting the `hotfix/<slug>` branch via
  `/nyann:cleanup-branches` once the merge lands.

## When to hand off

- "Just create a feature branch" → `/nyann:branch fix <slug>` (no
  release-branch ceremony).
- "I already have the hotfix branch — just release it" → merge it
  into the release branch first (`git checkout <release> && git
  merge --no-ff <hotfix>`), then `/nyann:release --version <patch>`
  from that branch.
- "Pre-release, not patch" → `/nyann:release --version <stable>-rc.1`
  on the regular feature branch; release.sh's prerelease detection
  handles it.
