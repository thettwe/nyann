---
name: pr
description: >
  Open a GitHub pull request from the current branch, with a
  Conventional-Commits-style title and a body summarizing the commit
  range.
  TRIGGER when the user says "open a PR", "create a pull request",
  "push and PR", "submit this for review", "ship this PR", "open a
  draft PR", "file a PR for this branch", "/nyann:pr".
  Do NOT trigger on "merge the PR" / "approve the PR" / "review PR #N"
  — those are GitHub actions outside nyann's wedge. Do NOT trigger on
  "rebase" / "sync with main" / "update my branch" — that's the
  `sync` skill. Do NOT trigger when the user is on `main`
  or `master` (no PR to open); if detected, tell them to create a
  branch first and route to `new-branch`.
---

# pr

Wraps `bin/pr.sh`. Two modes:

1. **Context-only** (`--context-only`). Collects branch + commit range
   + suggested title without any network calls. The gh auth check is
   skipped entirely in this mode (the script exits with the JSON
   summary before reaching the gh guard), so context-only also works
   when `gh` isn't installed or authenticated. Use this when the user
   wants you to synthesize a PR title and body from the commits before
   shipping.
2. **Create** (default). Pushes the current branch with `-u` tracking
   and invokes `gh pr create` with your title + body. Returns the PR
   URL.

## 0. Drift check (quick, non-blocking)

Run `bin/session-check.sh` before starting. If it produces output,
show the one-line drift summary to the user as an informational note
(e.g. "Heads up: nyann detected drift vs your profile. Run
`/nyann:retrofit` when you get a chance."). Do not block the PR
flow — this is a nudge, not a gate.

## 1. Pre-flight

- Verify `gh` is installed and authenticated. `bin/pr.sh` does this
  and emits `{skipped, reason}` with reason `gh-not-installed` or
  `gh-not-authenticated`. If you see a skip, relay it cleanly; don't
  try to install `gh` for the user.
- Verify the current branch is not `main`/`master`. If it is, refuse
  and suggest `/nyann:branch` to create a feature branch first.
- Verify there are commits ahead of the base. If `ahead == 0`, tell
  the user there's nothing to PR and suggest they commit first.

## 2. Decide base branch

`bin/pr.sh` resolves base in this order: `--base` arg > upstream
tracking ref > `origin/HEAD` > `main`. Normally don't pass `--base`;
trust the resolution. Override only when the user explicitly names a
different target (e.g. "PR into develop").

## 3. Generate title + body

Run `bin/pr.sh --target <cwd> --context-only` first. Read the commit
list from the JSON. Then synthesize:

- **Title**: single Conventional-Commits line. If the branch has one
  commit, use that commit's subject verbatim. If many commits, pick
  the dominant type/scope and write a summary line. Keep it under
  ~70 chars for GitHub's UI.
- **Body**: GitHub-flavored markdown. Use this skeleton:
  ```
  ## Summary

  <2-4 bullets on what changed and why; derived from the commit list
  and any user intent they've shared>

  ## Test plan

  <bullets on what was verified; include lint / tests / manual checks
  the user has done in the session>
  ```
  When the user has shared context in the session (e.g. "I verified
  X locally"), fold it into the Test plan. Don't invent tests that
  weren't run.

## 4. Confirm before shipping

Show the user the proposed title and body. Ask "Ship it?" before
calling the create path. Exceptions: if the user's original phrasing
was "just open the PR" / "ship it now" / "don't ask, just PR it",
skip the confirmation.

## 5. Invoke create

```
bin/pr.sh \
  --target <cwd> \
  --title "<conventional-title>" \
  --body "<markdown-body>" \
  [--base <branch>] \
  [--draft]
```

`--draft` when the user says "draft PR" / "WIP PR" / "not ready for
review yet". Relay the URL from `{url}` in the output back to the
user.

## 6. Handling errors

- `gh pr create` can fail if a PR already exists for this branch. In
  that case, suggest the user switch to `gh pr edit` or `/nyann:commit`
  to add more commits — don't retry the create.
- `git push` can fail if the remote is ahead. Surface the error
  verbatim and suggest `/nyann:sync` or a manual pull+rebase.

## When to hand off

- "now merge it" / "approve it" → out of scope; explain nyann doesn't
  do merge/approve.
- "update my branch with main first" → `sync` skill.
- "write a commit message first" → `commit` skill.
