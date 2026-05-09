---
name: undo-bootstrap
description: >
  Reverse a bootstrap or retrofit run by walking its BootRecord manifest:
  restore pre-state files, drop branches that were created, surface
  anything that couldn't be safely undone. TRIGGER when the user says
  "undo the bootstrap", "undo nyann setup", "revert nyann setup",
  "uninstall nyann from this repo", "back out the bootstrap",
  "undo the retrofit", "I regret running bootstrap", "rip out nyann",
  "/nyann:undo-bootstrap". ALSO trigger when the user wants to roll back
  a /nyann:retrofit run that drifted things they didn't expect — retrofit
  remediation goes through bootstrap.sh, so its boot record is in the
  same place. DISAMBIGUATION: this is NOT `/nyann:undo` — that one
  rewinds git commits on a feature branch via `git reset`, completely
  separate from filesystem mutations bootstrap made. If the user just
  said "undo my last commit", route to `/nyann:undo` instead. Do NOT
  trigger on "uninstall the plugin" — that's a Claude Code plugin
  manager concern, not a per-repo undo. Do NOT trigger on
  "remove .git" / "delete the repo" — undo-bootstrap explicitly refuses
  to remove .git/ because doing so destroys all of the user's git state,
  not just bootstrap's.
---

# undo-bootstrap

Wraps `bin/undo-bootstrap.sh`. Read this end-to-end before invoking;
the refusal modes carry real meaning.

## 1. Locate the BootRecord

Boot records live under `<repo>/memory/.nyann/bootstraps/<ISO-ts>/`.
Each contains a `manifest.json` (the BootRecord) and a `pre-state/`
directory with original file bytes.

By default the script picks the newest manifest. When the repo has
multiple records (typical: one bootstrap + one or more retrofits),
**list them and ask** which to undo:

```bash
ls -1t memory/.nyann/bootstraps/*/manifest.json | head -10
```

Show the list with `created_at`, `source`, and a one-line summary
(extract via `jq -r '.created_at + "  " + .source + "  (" + (.actions | length | tostring) + " actions)"'`).
Pass the chosen one via `--manifest <path>`.

## 2. Always preview first

Run with `--dry-run` and surface the JSON to the user:

```bash
bin/undo-bootstrap.sh --target "$PWD" --dry-run
```

Walk the four arrays in the result: `restored`, `deleted`,
`branches_dropped`, `defaults_renamed_back`. Read `skipped[]` carefully
and explain each entry — they're the load-bearing communication.

For ambiguous cases (skipped entries with overrides available),
**use `AskUserQuestion`**:

```json
{
  "questions": [
    {
      "question": "Some files were modified after bootstrap finished. Override and overwrite local edits?",
      "header": "Force",
      "multiSelect": false,
      "options": [
        { "label": "No (Recommended)", "description": "Skip those files — your edits are safe; you can manually restore later." },
        { "label": "Yes, --force", "description": "Overwrite local edits with the pre-bootstrap state. Edits are LOST." }
      ]
    }
  ]
}
```

## 3. Refusal semantics

| Refusal reason | What to tell the user |
|---|---|
| `no boot records found` | "This repo has no bootstrap history nyann can see — has bootstrap ever run here?" |
| `manifest target mismatch` | "The boot record was made for a different repo. Pass `--manifest <path>` if you really want to apply it to this one." |
| `HEAD ahead of seed commit` | "You've made commits on top of the bootstrap. Pass `--allow-rebase` to drop them, or rebase first." |
| `manifest has unexpected shape` | "The record file is corrupt or from a different nyann version. Inspect it manually." |

Skipped entries (in the result JSON, not refusals):

| Skip reason | Override | Explanation |
|---|---|---|
| `modified after bootstrap` | `--force` | The file was edited since bootstrap. Restore would lose those edits. |
| `branch has commits past base_sha` | `--allow-non-empty-branches` | Long-lived branch (e.g., develop) has new commits. |
| `would delete a bootstrap-created file` | `--force` | Bootstrap created it; can't tell if user has since edited. |
| `seed commit left in place` | (none — manual git) | Seed commits are repo roots; removing them strands the branch. |
| `removing .git/ destroys all git state` | (none — manual `rm -rf .git`) | Permanent skip. |

## 4. Decide scope

Default `--scope all` reverses every category. Use narrower scopes when
the operator wants surgical undo:

```json
{
  "questions": [
    {
      "question": "Which parts of the bootstrap should be reversed?",
      "header": "Scope",
      "multiSelect": true,
      "options": [
        { "label": "All (Recommended)", "description": "Restore everything bootstrap touched." },
        { "label": "docs", "description": "docs/ and memory/ scaffolds, CLAUDE.md." },
        { "label": "hooks", "description": ".git/hooks/, .husky/, pre-commit, package.json mutations." },
        { "label": "gitignore", "description": ".gitignore merge." },
        { "label": "editorconfig", "description": ".editorconfig." },
        { "label": "github", "description": ".github/ workflows, templates, CODEOWNERS." },
        { "label": "branching", "description": "Branches created, default-branch renames." }
      ]
    }
  ]
}
```

## 5. Invoke

```bash
bin/undo-bootstrap.sh --target <cwd> \
  [--manifest <path>] \
  [--scope <csv>] \
  [--force] [--allow-rebase] [--allow-non-empty-branches] \
  [--dry-run] \
  --yes
```

Without `--yes`, the script returns `status: "preview"` and exits 0
without mutating — same idiom as `bin/undo.sh`.

## 6. Post-undo report

On success, walk the result JSON and tell the user:

- How many files were restored / deleted / branches dropped.
- Anything in `skipped[]` (with override hints).
- Whether the boot record was cleaned up (it is, when no
  reversible-but-deferred skips remain) or kept (run again with
  `--force` / `--allow-non-empty-branches` to finish the job).

For seed-commit skips, suggest the manual command:
```bash
git update-ref -d refs/heads/<branch>   # only if you really want a fresh start
```

Don't run that automatically — it strands the working tree.

## 7. Hand-off

- "Now run bootstrap again with a different profile" → `/nyann:bootstrap`.
- "Undo just the docs part" → re-run with `--scope docs` (works even
  after a previous full undo if the manifest was kept).
- "I want to keep the manifest as a record" → re-run with `--keep-record`.
