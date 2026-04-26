---
name: learn-profile
description: >
  Inspect a reference repo and save its nyann-relevant setup (stack,
  hooks, branching, commit convention, extras) as a reusable profile.
  TRIGGER when the user says "save this setup as a profile called X",
  "learn a profile from ~/projects/foo", "capture this repo's setup as
  my-profile", "make a profile from this repo", "turn this repo into a
  profile", "extract a profile from <path>", "remember this setup as
  <name>", "/nyann:learn-profile".
  Do NOT trigger on "what does this profile do?" — that's `inspect-profile`. Do NOT trigger on "apply profile X to this repo" —
  that's `bootstrap-project`. Do NOT trigger on "fix drift" — that's
  `bootstrap-project` retrofit.
---

# learn-profile

Read-only inspection of a reference repo. Writes one JSON file (the new
profile) to the user's profile root. Never touches the reference repo
itself.

## 1. Resolve inputs

Need two things:

- **`--target <path>`** — the reference repo to learn from. Default to
  the current working directory only if the user says "this repo";
  otherwise ask for the path explicitly. Profile learning from the
  wrong repo produces a confusing profile, so err on the side of
  confirming.
- **`--name <slug>`** — the profile name. Must match
  `^[a-z0-9][a-z0-9-]*$`. If the user offers a name with spaces or
  caps (e.g. "My Next Starter"), propose a slug (`my-next-starter`)
  and confirm before running.

Optional:

- **`--user-root <dir>`** defaults to `~/.claude/nyann`. Only pass
  explicitly when the user wants a different root.
- **`--stdout`** when the user wants to inspect the inferred JSON
  without writing it to disk. Useful for "show me what you'd save".

## 2. Pre-flight checks

- Confirm the target path exists and is a directory. If it's not a git
  repo, say so — the inference loses most of its signal (branching
  strategy comes from branches + tags, commit convention from subject
  history). Offer to continue anyway, but warn.
- Check whether a profile with the same name already exists at
  `<user-root>/profiles/<name>.json`. If it does, ask the user whether
  to overwrite or pick a different name. Never silently clobber.

## 3. Invoke

```
bin/learn-profile.sh \
  --target <resolved-path> \
  --name <slug> \
  [--user-root <dir>] \
  [--stdout]
```

Expected exit codes:

| Code | Meaning | What to do |
|---|---|---|
| 0 | profile written | Tell the user the path + show the inferred summary |
| 1 | bad input (missing target, invalid name, etc.) | Surface the error verbatim; fix and retry |
| other | internal failure | Surface stderr and stop — don't paper over |

## 4. Report back

On success, show the user:

- **Where** the file was written (`~/.claude/nyann/profiles/<name>.json`).
- **What was inferred** — read back the key fields (primary_language,
  framework, branching strategy, commit_format, hook list). Any field
  marked `"inferred": true` in the output came from heuristics rather
  than explicit config; call those out so the user knows to double-check.
- **Next step** — "To apply this profile to a new repo, run
  `bootstrap-project` with `--profile <name>`" (or the matching natural
  language).

## 5. Handling weak signal

`learn-profile` reads:

- `detect-stack.sh` output → stack block
- `.husky/`, `.pre-commit-config.yaml`, `commitlint.config.*`, installed
  git hooks → hooks block
- Last 50 commit subjects → `conventions.commit_format`
- Branches + tags → `branching.strategy`
- `.editorconfig`, `.gitignore` → extras block

When evidence is thin (e.g. a fresh repo with 2 commits), the inferred
profile will be sparse. That's fine — flag it to the user ("I could
only infer X and Y; everything else defaults"). Don't invent data to
fill gaps.

## When to hand off

- User asks "now use this profile in a new repo" → `bootstrap-project`
  with `--profile <name>`.
- User asks "what does this profile do?" → `inspect-profile` or read
  the JSON directly.
- User asks to share the profile with a team → mention
  `add-team-source` for the team-profile side; `learn-profile` itself
  only writes to the user root.
