---
name: cleanup-branches
description: >
  Prune local branches whose work is already merged into the base.
  TRIGGER when the user says "clean up branches", "delete merged branches",
  "prune local branches", "remove old branches", "I have too many branches",
  "what branches can I delete", "/nyann:cleanup-branches".
  Do NOT trigger on "delete THIS branch" (that's a one-off `git branch -D`,
  not a cleanup pass) or "remove a branch from the remote" (this skill is
  local-only; remote pruning is `git push --delete origin <branch>` and
  the user should do that themselves). Do NOT trigger on "merge this branch"
  (that's the merge step before cleanup).
---

# cleanup-branches

Wraps `bin/cleanup-branches.sh`. Lists local branches whose tip is
reachable from the base branch (`main` / `develop` / wherever the
profile points), then either previews the list or actually deletes
them with `git branch -d` (safe — refuses unmerged work).

Mirrors the same preview-then-mutate contract as `undo` and
`switch-profile`: nothing is deleted unless the caller passed
`--yes` AND `--dry-run` was absent.

## 1. Run the preview

Always invoke without `--yes` first:

```
bin/cleanup-branches.sh --target <cwd>
```

Output is a CleanupBranchesResult JSON (see
`schemas/cleanup-branches-result.schema.json`). Show the user:

- The base branch the merge check ran against (`base_branch`).
- The list of candidates (`candidates[]`), one per merged branch,
  with last-commit timestamp + short SHA so they can sanity-check.
- The total count from `summary.candidates_count`.
- The recovery hint: re-run with `--yes` to delete.

If `summary.candidates_count == 0`, tell the user there's nothing
to clean up and exit. Don't prompt.

## 2. Confirm and apply

Ask: "Delete N merged branch(es)?" — list the names if there are 5
or fewer, or summarise if more. On confirmation:

```
bin/cleanup-branches.sh --target <cwd> --yes
```

The script uses `git branch -d` (lowercase d, the safe form) so even
if a candidate's merge state changed between the preview and the
apply, git will refuse the unsafe delete and the entry lands in
`errors[]` instead of `deleted[]`. Surface any errors verbatim.

## 3. After deletion

- Report `summary.deleted_count` and any entries in `errors[]`.
- Suggest the user push the deletions to the remote if they
  maintain a personal fork branch list:
  ```
  git push --delete origin <branch>   # per branch
  ```
  Don't run this for them — pushing is a high-blast-radius action
  and the user should pick which deletions to mirror.

## When to hand off

- "Why is X still here?" → it's not reachable from base. Run
  `/nyann:doctor` and look at the `LOCAL BRANCHES` row for
  `stale_unmerged` count, or invoke `bin/check-stale-branches.sh`
  directly to see the full classification.
- "Delete a specific branch by name" → just `git branch -D <name>`.
  This skill is for the bulk-merged case.
- "Prune the remote-tracking refs too" → `git remote prune origin`
  is what they want; not in scope here.
