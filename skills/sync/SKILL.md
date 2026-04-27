---
name: sync
description: >
  Update the current feature branch with the latest changes from its
  base branch (rebase by default, merge when asked).
  TRIGGER when the user says "sync with main", "update my branch",
  "rebase on main", "catch up with main", "pull in main", "bring
  this branch up to date", "merge main into this branch",
  "/nyann:sync". Trigger on "resolve conflicts" only when the user
  specifically ties it to syncing — otherwise that's a manual resolve.
  Do NOT trigger on "pull" alone (that's a different operation for
  updating main itself). Do NOT trigger on main/master/develop — those
  are long-lived branches and sync-skill refuses them. Do NOT trigger
  on commit / push / PR — those are separate skills.
---

# sync

Wraps `bin/sync.sh`. Rebases (or merges) the current feature branch
onto its base, after a clean-tree + branch-safety check.

## 1. Pre-flight (the script does these; your job is to interpret them)

- **Not a git repo** (exit 2) → tell the user; stop.
- **Detached HEAD / main / master / develop** (exit 2) → refuse with
  a clear message; suggest switching to a feature branch first
  (`/nyann:branch` creates one).
- **Dirty working tree** (status=`dirty` in JSON) → stop and tell the
  user to commit or stash first. Don't silently stash on their behalf
  — `git stash` is a footgun when the rebase also conflicts.

## 2. Choose strategy

Default to `rebase`. Use `merge` when:

- The user explicitly says "merge" (not "rebase").
- The profile's branching strategy is `gitflow` and the target base
  is `develop`/`main` (shared long-lived branches — some teams ban
  rebase on these).
- The branch has already been pushed to a shared remote and has open
  PRs (rebasing rewrites history; merges don't).

If unclear, use `AskUserQuestion` to pick:

- header: "Sync strategy"
- options:
  - "Rebase (Recommended)" — keeps history linear; replays your commits on top of base
  - "Merge" — preserves original commits; adds a merge commit

## 3. Resolve base

`bin/sync.sh` picks base via: `--base` > `@{upstream}` > `origin/HEAD`
> `main`. Override only when the user explicitly names a different
target ("sync against develop"). Normally trust the resolution.

## 4. Invoke

```
bin/sync.sh --target <cwd> [--strategy rebase|merge] [--base <branch>] [--dry-run]
```

`--dry-run` reports what would happen without mutating. Use it when
the user is cautious or you want to show them the ahead/behind count
first.

## 5. Interpret the output JSON

| status | meaning | what to tell the user |
|---|---|---|
| `up-to-date` | behind == 0 | "Already up to date with `<base>`." No action needed. |
| `synced` | operation completed | "Synced via `<strategy>`. Now `<ahead>` ahead, 0 behind." |
| `dirty` | working tree had uncommitted changes | "Working tree has uncommitted changes. Commit or stash first." |
| `skipped` | base not found locally or on origin | "Couldn't find `<base>` locally or on origin. Check the branch name." |
| `conflicts` | rebase/merge halted mid-operation | See §6 — this is the tricky case. |

## 6. When conflicts happen

The script stops and leaves the working tree in a rebase-in-progress
or merge-in-progress state. Do NOT call sync again — the script
doesn't know how to resume.

Read the `conflicts[]` array from the JSON. For each file, offer to
help resolve it (read the file, show conflict markers, ask the user
which side to keep). When the user is done:

- **For rebase**: `git add <resolved-files>` then `git rebase --continue`.
- **For merge**: `git add <resolved-files>` then
  `git -c user.email=... -c user.name=... commit --no-edit` to finalize.

If the user wants to bail: `git rebase --abort` or `git merge --abort`.
Either returns the working tree to its pre-sync state.

## When to hand off

- "Now push and PR" → `pr` skill.
- "The conflicts are too messy, just abort" → run `git rebase --abort`
  / `git merge --abort` yourself and confirm.
- "Update main itself" → out of scope; tell the user `git checkout main
  && git pull` handles that.
