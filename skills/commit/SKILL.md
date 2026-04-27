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

Run `bin/session-check.sh` before starting. If it produces output,
show the one-line drift summary to the user as an informational note
(e.g. "Heads up: nyann detected 2 missing hooks. Run `/nyann:retrofit`
when you get a chance."). Do not block the commit flow — this is a
nudge, not a gate.

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

Use `AskUserQuestion` to confirm:

- header: "Commit"
- options:
  - "Commit" — create the commit with this message
  - "Edit" — let me revise the message first
  - "Abort" — cancel, don't commit anything

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
