---
name: new-branch
description: >
  Create a strategy-compliant git branch. TRIGGER when the user says
  "create a branch for X", "start a feature branch", "new fix branch",
  "cut a release branch", "start a hotfix", "branch for bug in Y",
  "make a branch named X", "/nyann:branch".
  DISAMBIGUATION: if the user mentions BOTH branch creation AND committing
  in the same message (e.g. "branch and commit", "start a branch and
  commit this"), this skill wins — create the branch first, then suggest
  `/nyann:commit` (or the commit skill) as the follow-up.
  Do NOT trigger on informational questions about branches ("what branch
  am I on?") or on general git-history questions.
---

# new-branch

You are creating a git branch that matches the repo's active profile.
Never run `git branch` or `git checkout -b` directly — route through
`bin/new-branch.sh` so the branching strategy, base branch, and name
pattern stay consistent.

## 1. Infer purpose

Read the user's phrasing. Purpose inference:

| User says something like... | Purpose |
|---|---|
| "new feature for X", "landing page", "add X" | `feature` |
| "bug in checkout", "fix Y", "bugfix" | `bugfix` |
| "release v1.2", "cut a release" | `release` |
| "hotfix production", "emergency fix" | `hotfix` |

If the phrasing is ambiguous ("I want a branch for the auth work"),
ask which of `feature` / `bugfix` applies. Don't guess when stakes are
non-trivial (release vs hotfix especially).

## 2. Derive a slug

Short, lowercase-kebab, no spaces. Map the user's words:

- "bug in the checkout button" → `checkout-button`
- "add a landing page" → `landing-page`
- "v1.2.0" release → slug is `1.2.0`, use `--version 1.2.0` (see below).

Enforce the regex `^[a-z0-9][a-z0-9._-]*$`. If the user's phrasing
doesn't reduce to a clean slug, propose one and ask for confirmation.

## 3. Release / hotfix version flag

`release` and `hotfix` patterns in GitFlow use `{version}` not `{slug}`.
For those purposes, ask the user which version (unless they already
said), then pass `--version <x.y.z>` to the orchestrator.

## 4. Invoke the orchestrator

```
bin/new-branch.sh \
  --target <cwd> \
  --profile <active-profile-name> \
  --purpose <feature|bugfix|release|hotfix> \
  --slug <slug> \
  [--version <x.y.z>] \
  --checkout
```

Exit codes you should expect:

| Code | Meaning | What to do |
|---|---|---|
| 0 | created (and checked out if --checkout) | Report the new branch name |
| 2 | profile not found | Ask user to run bootstrap, or pick a different profile |
| 3 | purpose not supported by strategy / placeholder left | Tell user (e.g. GitHub Flow has no `release`) |
| 4 | slug invalid | Tell user + proposed fix |
| 5 | branch already exists, no `--checkout` | Offer to switch or suggest a different slug |

## 5. Report

On success, print:

- The new branch name.
- The base branch it was created from.
- One-line "next step" suggestion (e.g. "start making your changes, then
  run `/nyann:commit`").

## When something goes wrong

- Strategy doesn't support the purpose (e.g. GitHub Flow + `release`) →
  tell the user; suggest creating a release tag instead if that's their
  intent.
- `main`/`master` doesn't resolve → the repo wasn't bootstrapped; run
  `/nyann:bootstrap` first to seed.
- Slug collision on a prior PR → suggest `-v2` or a more specific slug
  rather than silently appending.

## When to hand off

- "Now commit my changes" → `commit` skill.
- "Open a PR from this branch" → `pr` skill (PR only) or `ship` skill
  (PR + merge).
- "Sync this branch with main" → `sync` skill.
