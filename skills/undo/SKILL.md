---
name: undo
description: >
  Safely undo the most recent git commit(s) on a feature branch.
  TRIGGER when the user says "undo my last commit", "undo last N
  commits", "oops revert that commit", "undo the commit but keep my
  changes", "uncommit", "revert my last change", "take back that
  commit", "/nyann:undo". Trigger on "revert" only when the user
  clearly means undoing a local commit (not `git revert` on a
  published one — see DISAMBIGUATION).
  DISAMBIGUATION: if the user says "revert a commit that's already
  on main" / "revert a pushed commit" / mentions a specific remote
  SHA, this is the `git revert` workflow — undo-skill refuses pushed
  commits by default. Explain the difference and either use
  --allow-pushed (risky) or direct them to `git revert <sha>`.
  Do NOT trigger on "undo the last edit" (that's editor-level) or
  "rollback the deploy" (that's infrastructure, out of scope).
  Do NOT trigger on main/master/develop — long-lived branches should
  never be history-rewritten; use `git revert` instead.
---

# undo

Wraps `bin/undo.sh`. History-mutating operation — treat as destructive.

## 1. Always preview first

Before any mutation, run `bin/undo.sh --dry-run` and show the user
which commits will be undone. The preview JSON lists them newest-
first with SHA and subject. Read it back and ask the user to
confirm — even for a single-commit undo.

Exception: the user's request explicitly included "don't ask" / "just
do it" AND `--count` is 1 AND `--strategy` is `soft` (the safest
default). For anything multi-commit or non-soft, always confirm.

## 2. Decide strategy

Default is `soft` (safest — all changes stay staged). When the user's
intent is unclear, **you MUST call the `AskUserQuestion` tool** (not
plain text):

```json
{
  "questions": [
    {
      "question": "How should the commit be undone?",
      "header": "Strategy",
      "multiSelect": false,
      "options": [
        { "label": "Soft (Recommended)", "description": "Undo commit, keep changes staged" },
        { "label": "Mixed", "description": "Undo commit, keep changes in working tree (unstaged)" },
        { "label": "Hard", "description": "Undo commit AND discard all changes permanently" }
      ]
    }
  ]
}
```

For `hard`, warn the user twice: the work is gone after hard reset.
Confirm before executing even after the picker selection.

## 3. Decide scope

- **`last-commit`** (default) — one commit.
- **`last-N-commits` with `--count <N>`** — multiple commits. Use
  when the user says "undo the last 3 commits" or similar.

`last-N-commits` is more dangerous because commits partway down the
stack are harder to recover. For N > 3, suggest using `git reflog`
+ targeted revert instead of a bulk reset.

## 4. Pre-flight safety (script enforces; relay messages)

| Refusal reason | What to tell the user |
|---|---|
| `long-lived branch` | "Can't undo on main/master/develop. Use `git revert <sha>` to create a reverting commit." |
| `merge commit` | "HEAD is a merge commit — undo with `git revert -m 1 <merge-sha>` manually." |
| `already on upstream` | "The commit is already pushed to `<upstream>`. Either `git revert` it (safe) or pass `--allow-pushed` to force-push after the reset (only if nobody else pulled)." |
| `detached HEAD` | "Detached HEAD — checkout a branch first." |
| `fewer than N commits` | "Branch only has M commits; can't undo N." |

## 5. Invoke

```
bin/undo.sh --target <cwd> \
  [--scope last-commit|last-N-commits] [--count N] \
  [--strategy soft|mixed|hard] [--allow-pushed] [--dry-run]
```

## 6. Post-undo report

On success, echo back:

- What was undone (subjects from `undone_commits`).
- The new HEAD SHA.
- Where the changes are now: staged (soft), in working tree (mixed),
  or gone (hard).
- For `soft`/`mixed`: suggest `git status` to see what's pending.
- For multi-commit undo: remind the user that `git reflog` can
  recover the discarded history if they change their mind soon.

## 7. Hand-off

- "Re-commit with a new message" → `commit` skill after undo.
- "Now push the rewrite" → if undo required force-push (pushed
  commit with `--allow-pushed`), they'll need `git push --force-with-lease`.
  Don't run this automatically; explain and let them decide.
- "Undo the undo" → `git reflog` + `git reset --hard <prior-sha>`.
  Handle this as a separate one-off; don't add reflog logic to the
  undo skill itself.
