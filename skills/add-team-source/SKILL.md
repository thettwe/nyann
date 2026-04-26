---
name: add-team-source
description: >
  Register a git URL as a team-profile source so nyann can periodically
  sync and expose its profiles under a namespace.
  TRIGGER when the user says "add a team profile source", "register a
  team profile source", "set up team profiles from <url>", "wire up
  our team's shared profiles at <repo>", "add profile source named
  X at <url>", "install team profiles from <git repo>",
  "/nyann:add-team-source".
  Do NOT trigger on "sync team profiles now" (that's
  `sync-team-profiles` — the pull operation). Do NOT trigger on
  "save my setup as a profile" (that's `learn-profile` — writes to
  user root, not a team source). Do NOT trigger on generic "add a
  repo" or "add a remote" — those are git operations unrelated to
  profile distribution.
---

# add-team-source

Wraps `bin/add-team-source.sh`. Updates
`~/.claude/nyann/config.json` to declare a new team-profile source.
Idempotent — passing the same `--name` updates the entry in place.

## 1. Collect inputs

- **`--name <id>`** — required. Short slug, `^[a-z0-9][a-z0-9-]*$`.
  Will also become the namespace prefix for team profiles (e.g.
  `platform-team/base` when name is `platform-team`). When the user
  gives a name with spaces or caps, propose a slug and confirm.
- **`--url <git-url>`** — required. Any URL git can clone
  (https://, git@, file:// for testing).
- **`--ref <branch-or-tag>`** — default `main`. Override when the
  team pins a specific branch or tag.
- **`--interval <hours>`** — default `24`. How often
  `sync-team-profiles` will re-pull from this source without
  `--force`. Decrease only when the user says "we update these
  often" or similar.

## 2. Pre-flight

- Config path defaults to `~/.claude/nyann/config.json`. Override
  only when the user explicitly names a different user root.
- The backend upserts on `--name` collision. Warn the user if
  they're replacing an existing source with a different URL —
  that's usually unintentional. Read current config first if unsure.

## 3. Invoke

```
bin/add-team-source.sh \
  --name <id> \
  --url <git-url> \
  [--ref <branch>] \
  [--interval <hours>] \
  [--user-root <dir>]
```

Exit 0 on success; config path is logged to stderr.

## 4. Report back

- Name, URL, ref, interval.
- Tell the user "Run `/nyann:sync-team-profiles` (or ask 'sync my
  team profiles') to actually pull them". `add-team-source` only
  registers — the pull is a separate operation on purpose (no
  surprise network calls here).

## When to hand off

- "Now pull them" → `sync-team-profiles` skill.
- "Apply a team profile to this repo" → `bootstrap-project` with
  the namespaced profile name (e.g. `platform-team/base`).
- "Show what the team profile does" → `inspect-profile` with the
  namespaced name.
