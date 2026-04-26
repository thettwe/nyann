---
name: inspect-profile
description: >
  Explain in plain English what a nyann profile enables — stack,
  branching, hooks, extras, conventions, documentation.
  TRIGGER when the user says "what does the nextjs-prototype profile
  do", "explain the python-cli profile", "show me what <name>
  enables", "what's in profile X", "describe the <name> profile",
  "inspect profile X", "/nyann:inspect-profile".
  Do NOT trigger on "show this repo's setup" — that's the
  `explain-state` skill (reads the repo, not a profile file). Do
  NOT trigger on "apply profile X to this repo" — that's
  `bootstrap-project`. Do NOT trigger on "save this setup as a
  profile" — that's `learn-profile`.
---

# inspect-profile

Read-only. Wraps `bin/inspect-profile.sh`. Loads a profile via
`load-profile.sh` (user profiles shadow starters with the same name)
and renders a human-readable summary.

## 1. Resolve the profile name

- The user names it explicitly most of the time ("what does
  `nextjs-prototype` do"). Use that.
- If the user is ambiguous ("what does my profile do"), ask — the
  skill doesn't infer from the repo. For "show this repo's setup",
  route to `explain-state` instead.
- Names match the regex `^[a-z0-9][a-z0-9-]*$`. Reject anything else
  with a clear message rather than handing a bad name to the backend.

## 2. Invoke

```
bin/inspect-profile.sh <name> [--user-root <dir>]
```

`--user-root` defaults to `~/.claude/nyann`. Only override when the
user says something like "check my team-installed profile at
`<path>`".

## 3. Read the output back

The backend already formats sections (Profile, Stack, Branching,
Hooks, Extras, Conventions, Documentation, GitHub integration). Your
job is to relay those faithfully and add context when the user asks
a follow-up. Don't re-summarize — the backend's blurbs for each hook
(e.g. "ESLint runs on staged JS/TS") are authoritative.

When the user asks "is this the right profile for my repo", do NOT
guess — suggest running `explain-state` (reads the repo) and
comparing, or running `doctor` (reports drift against a chosen
profile).

## 4. Handle "not found"

Exit code 2 means the profile isn't in user root or starters. The
backend prints the available list; relay it and ask the user to
pick one. Never invent profile names.

## 5. Handle shadow warnings

`load-profile.sh` warns on stderr when a user profile shadows a
starter with the same name. Don't hide this — explicitly tell the
user which version was loaded (user wins by design).

## When to hand off

- "Apply this profile to a new repo" → `bootstrap-project` with
  `--profile <name>`.
- "Change something in this profile" → edit the JSON at
  `~/.claude/nyann/profiles/<name>.json`; the skill doesn't mutate.
- "Save my repo's current state as a profile named X" →
  `learn-profile`.
- "Why doesn't my repo match this profile" → `doctor` against the
  named profile.
