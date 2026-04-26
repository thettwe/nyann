---
name: setup
description: >
  First-run onboarding for nyann. Creates the user config directory,
  collects preferences through a conversational flow, and writes
  ~/.claude/nyann/preferences.json.
  TRIGGER when the user says "set up nyann", "configure nyann",
  "nyann setup", "onboard me", "first time using nyann", "initialize
  nyann", "nyann first run", "get nyann ready", "/nyann:setup".
  ALSO trigger when: the user runs any nyann command for the first time
  and ~/.claude/nyann/preferences.json does not exist — suggest running
  setup first, but don't block them.
  Do NOT trigger on "set up this project" or "bootstrap this repo" —
  those are bootstrap-project. Do NOT trigger on "check prereqs" — that
  is check-prereqs. This skill configures nyann itself, not a repo.
---

# setup

Interactive onboarding that configures nyann for the current user.
Creates directory structure and collects preferences so downstream
skills (bootstrap, doctor, commit, etc.) have sensible defaults.

Re-runnable: if preferences already exist, show current values and
offer to update them.

## Phase 1: Welcome and status check

1. Run `bin/setup.sh --check --json` to see if preferences already exist.
2. If **already configured**:
   - Show the current preferences as a readable summary.
   - Ask: "Want to update any of these, or are you good?"
   - If they want to update, continue to Phase 3 but pre-fill current
     values as defaults (user just presses enter to keep).
   - If they're good, skip to Phase 5.
3. If **not configured**:
   - Welcome the user briefly: "Let's get nyann configured. I'll ask a
     few questions about your preferences — takes about a minute."
   - Continue to Phase 2.

## Phase 2: Prerequisites check

Run `bin/check-prereqs.sh` and show the output. This is informational —
don't block setup on soft prereq misses. Only warn if a hard prereq is
missing (exit code 1); in that case, tell the user what to install but
still continue setup since preferences don't depend on tools.

## Phase 3: Collect preferences

Ask each question one at a time. Keep the conversation natural — don't
dump all questions at once. Show the default in brackets. Accept short
answers ("github flow", "cc", "local", "yes/no").

### 3.1 Default profile

> What stack do you work with most often? This sets which profile nyann
> picks when you don't specify one during bootstrap.

Options:
- **auto-detect** (default) — nyann inspects the repo each time
- A specific starter profile name: `nextjs-prototype`, `react-vite`,
  `node-api`, `typescript-library`, `fastapi-service`, `django-app`,
  `python-cli`, `go-service`, `rust-cli`, `swift-ios`, `kotlin-android`,
  `shell-cli`, `default`

List the options grouped by language. If the user says something like
"I mostly do Python FastAPI", map that to `fastapi-service`. If they
work across multiple stacks, recommend `auto-detect`.

### 3.2 Branching strategy

> What branching strategy do you usually follow?

Options:
- **auto-detect** (default) — nyann picks based on project size/type
- **github-flow** — simple: main + feature branches
- **gitflow** — main + develop + feature/release/hotfix branches
- **trunk-based** — short-lived branches, frequent merges to main

Brief each option in one sentence when the user seems unsure. Most
individual developers want `github-flow`; teams with release cycles
want `gitflow`; CI-heavy teams want `trunk-based`.

### 3.3 Commit format

> Do you use Conventional Commits (feat:, fix:, etc.)?

Options:
- **conventional-commits** (default) — nyann enforces CC format in hooks
- **custom** — no commit format enforcement

If they say "yes", "CC", "conventional", or similar → `conventional-commits`.
If "no", "freestyle", "custom" → `custom`.

### 3.4 GitHub CLI integration

> Do you use the GitHub CLI (`gh`)? Nyann can set up branch protection
> and PR helpers when it's available.

Options:
- **yes** (default) — enable when `gh` is installed and authenticated
- **no** — skip all `gh`-dependent features

Check `command -v gh` before asking. If gh isn't installed, mention
that and default to no. If it is installed, default to yes.

### 3.5 Documentation storage

> Where should nyann route generated docs (architecture docs, ADRs,
> etc.)?

Options:
- **local** (default) — docs/ directory in the repo
- **obsidian** — route to an Obsidian vault via MCP
- **notion** — route to Notion via MCP

For obsidian/notion, note that they'll need the corresponding MCP
connector configured. Most users should start with local.

### 3.6 Team profile auto-sync

> Do you use shared team profiles? If yes, nyann can auto-sync them
> when they're stale during bootstrap.

Options:
- **no** (default) — manual sync only via `/nyann:sync-team-profiles`
- **yes** — auto-sync during bootstrap when interval expires

If they don't know what team profiles are, briefly explain: "Team
profiles let your org share standardized project configs. If you don't
have any, just say no — you can set them up later with
`/nyann:add-team-source`."

## Phase 4: Write preferences

Assemble the flags and run `bin/setup.sh`:

```
bin/setup.sh \
  --default-profile <value> \
  --branching-strategy <value> \
  --commit-format <value> \
  --gh-integration | --no-gh-integration \
  --documentation-storage <value> \
  --auto-sync-team-profiles | --no-auto-sync-team-profiles
```

Show the result summary from the script output.

## Phase 5: Next steps

After setup completes, suggest (don't auto-run):

1. **"Run `/nyann:check-prereqs` to see what tools are available."**
   — if prereqs weren't checked in Phase 2 (re-run case).
2. **"Run `/nyann:bootstrap` in a project to set it up."**
   — the primary next action for first-time users.
3. **"Run `/nyann:add-team-source` to register shared profiles."**
   — only mention if they said yes to team profiles or seemed interested.
4. **"Run `/nyann:setup` again anytime to update preferences."**
   — so they know it's re-runnable.

## When to hand off

- "Now bootstrap this repo" → `bootstrap-project` skill.
- "Check my tools" → `check-prereqs` skill.
- "Add team profiles" → `add-team-source` skill.
- "What does nyann do?" → explain with a pointer to the README, don't
  re-explain the full feature set here.
