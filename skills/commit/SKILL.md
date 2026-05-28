---
name: commit
description: >
  Generate a Conventional Commits message from the staged diff and create
  the commit after user confirmation. TRIGGER when the user says "commit
  these changes", "commit this", "generate a commit message", "stage and
  commit", "commit with CC", "write a commit message", "summarize my diff
  into a commit", "/nyann:commit". Do NOT trigger on "git commit" in an
  informational context or when the user is just asking what a commit
  message means.
  DISAMBIGUATION: if the user mentions BOTH branch creation AND committing
  in the same message (e.g. "start a branch and commit this", "new branch +
  commit"), route to the `new-branch` skill FIRST; `commit` will take over
  after the branch is created.
  When nothing is staged, guide the user to stage first rather than
  silently staging everything.
---

# commit

You are generating a commit message for the user's staged changes. Work
in phases. Never run `git commit` until the user has confirmed the message.

## 0. Drift check (quick, non-blocking)

Run `bash bin/session-check.sh --flow=commit`. If it produces output,
surface the line to the user verbatim. Do not block the flow.

## 1. Gather context

Run `bin/commit.sh --target <cwd>`. The script emits a JSON context object
(`target`, `branch`, `on_main`, `convention`, `staged_files`, `summary`,
`diff`, `truncated`).

Exit code handling:

- `0` → JSON context emitted. Check the `nothing_staged` field:
  - `nothing_staged: true` → ask the user what they want to stage
    (`git add <paths>`, `git add -p`, or "everything"), then re-run.
  - Otherwise → full context available. Continue.
- `2` → not a git repo. Tell the user, stop.

If `on_main: true`, warn the user that the block-main hook will reject
the commit. Suggest they create a feature branch via the `new-branch`
skill before continuing.

## 1.5. Pre-action guards + commit hygiene

Run **both** of these before generating the message — they inform scope
choice and prevent obvious mistakes from reaching the commit message
step:

```
bash bin/pre-action-guard.sh --flow commit --target <cwd> [--profile <resolved-profile.json>]
bash bin/commit-hygiene.sh --target <cwd> [--profile <resolved-profile.json>]
```

### Guard handling (exit code)

| Exit | Meaning | Action |
|---|---|---|
| 0 | All guards passed (or only advisory warnings) | Surface any advisory `message` lines, continue |
| 3 | One or more critical guards failed | Surface the failing guard messages. Refuse to proceed unless the user passes `--skip-guards` explicitly (re-ask via AskUserQuestion). |
| 4 | One or more `confirm`-severity guards failed | Surface the failures. Call AskUserQuestion: "Proceed despite the warnings?" Only continue on explicit confirm. |

Don't silently pass critical failures. The `merge-conflict-markers`
guard catching `<<<<<<<` in the staged diff is exactly the case where
"warn and continue" would let a broken merge into a commit.

### Hygiene findings

`commit-hygiene.sh` emits `{scope_suggestion, incomplete_staging,
debug_artifacts, dead_code, summary}`. Surface them inline:

- `scope_suggestion.primary` (when non-null) — pre-fill the CC scope in
  §3 with this value unless the user objects.
- `incomplete_staging[]` — surface each entry as a short warning
  ("`package.json` staged but lockfile is modified-but-unstaged").
  Don't block; the user may genuinely intend a partial commit.
- `debug_artifacts[]` — show file:line:match. Ask the user via
  AskUserQuestion whether to abort + clean up, or continue.
- `dead_code[]` — show file:line:name. Same prompt as debug artifacts.

If `summary.warnings == 0`, skip the hygiene surface entirely — quiet
when there's nothing to say.

## 2. Pick a convention

Read `context.convention`:

| value | meaning | reference |
|---|---|---|
| `conventional-commits` | commitlint.config.* present; CC format enforced | references/conventional-commits.md |
| `commitizen` | `.pre-commit-config.yaml` has commitizen; CC format with stricter body/footer rules | references/conventional-commits.md + commitizen notes |
| `default` | no framework configured; core commit-msg hook regex applies (CC format too) | references/conventional-commits.md |

In every case you are writing **Conventional Commits**. Load
`references/conventional-commits.md` for the authoritative rules and
examples before generating.

## 3. Generate the message

Using the diff + file summary + convention, write a message with this shape:

```
<type>[(<scope>)][!]: <description>

[optional body — wrap at 72 chars, use imperative mood]

[optional footers: "Closes #N", "BREAKING CHANGE: ..."]
```

Rules you must respect (full rationale in the reference):

1. `<type>` ∈ {feat, fix, chore, docs, refactor, test, perf, ci, build, style, revert}.
2. Subject ≤ 72 chars, no trailing period, imperative mood ("add", not "added").
3. Use `!` before the `:` ONLY when the change is a breaking public-API change.
   Pair with a `BREAKING CHANGE:` footer if so.
4. Scope (in parens) is a noun naming the subsystem. Infer from the touched paths.
5. Multi-file diffs pick the dominant change — never "feat: misc updates".
6. If a single commit mixes feat + fix + chore, tell the user it should be
   split. Don't invent a catch-all subject.
7. `Closes #N` / `Fixes #N` go in the footer block only — never in the subject.

## 4. Preview and confirm

Show the user the generated message plus:

- The active convention (so they know what's being enforced).
- Which files are in the commit.
- A one-line reminder they can edit before you commit.

**You MUST call the `AskUserQuestion` tool** (not plain text) to confirm:

```json
{
  "questions": [
    {
      "question": "Proceed with this commit message?",
      "header": "Commit",
      "multiSelect": false,
      "options": [
        { "label": "Commit", "description": "Create the commit with this message" },
        { "label": "Edit", "description": "Let me revise the message first" },
        { "label": "Abort", "description": "Cancel, don't commit anything" }
      ]
    }
  ]
}
```

## 5. Commit

Invoke `bin/try-commit.sh --target <target> --subject <subject> [--body <body>]`.
It attempts `git commit` and emits a structured JSON result instead of
failing the tool call, so you can branch on `result`:

```json
{"result":"committed","sha":"abc123","subject":"feat: ...","stage":null,"reason":null,"exit_code":0}
{"result":"rejected","sha":null,"subject":"...","stage":"commit-msg","reason":"<hook stderr>","exit_code":1}
{"result":"error","sha":null,"subject":"...","stage":null,"reason":"<stderr>","exit_code":N}
```

Never pass `--no-verify`. The commit-msg hook is a safety net, not noise.

## 6. Retry on hook rejection

If `result == "rejected"` and `stage == "commit-msg"`:

1. Parse `reason` for the hook's failure line (typically the regex it
   wanted or the specific rule that rejected the subject).
2. Regenerate the message with that constraint folded in. Keep the
   original user-facing scope/intent; only adjust the form.
3. Invoke `try-commit.sh` again with the corrected subject.
4. **Cap at 2 retries.** If the third attempt also fails, stop: show the
   user the last rejection's `reason` + the message you tried, and ask
   for manual input. Do not loop further. Do not suggest `--no-verify`.

For `result == "rejected"` on `pre-commit` stage, the user usually needs
to fix their working tree (formatter / linter / block-main). Surface the
reason verbatim and stop — don't try to auto-fix code.

For `result == "error"` (non-hook failure, e.g. identity missing), pass
the reason verbatim to the user. They fix their environment.

## Output summary

On success, end with:

- The committed SHA (`git rev-parse HEAD`).
- The subject line.
- Any footer (scope / breaking change note) worth highlighting.

## When something goes wrong

- `nothing_staged: true` in the JSON → ask what to stage, then re-run
  §1. Don't assume "everything".
- User says "abort" → exit cleanly. Nothing to undo.
- Two retries failed → print the last hook error + the generated message;
  ask the user to rewrite. Don't loop further.
- `git commit` errors for non-hook reasons (e.g. author missing) → surface
  the git error verbatim; the user fixes their environment.

## When to hand off

- "Now open a PR" / "ship it" → `pr` skill (PR only) or `ship` skill
  (PR + merge in one step).
- "Sync my branch with main first" → `sync` skill.
- "I need a new branch first" → `new-branch` skill.
- "Undo that commit" → `undo` skill.

## Reference

Details: `references/conventional-commits.md`.
