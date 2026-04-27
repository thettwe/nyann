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
   The script always exits 0; branch on the `status` field in the JSON.
2. If `status == "configured"`:
   - Show the current preferences as a readable summary.
   - Ask: "Want to update any of these, or are you good?"
   - If they want to update, continue to Phase 3 but pre-fill current
     values as defaults (user just presses enter to keep).
   - If they're good, skip to Phase 5.
3. If `status == "not_configured"`:
   - **Never dump the raw JSON to the user.** Instead, greet them:

     > **Welcome to nyann!** It looks like this is your first time.
     > Let's get you set up — I'll ask a few questions about your
     > preferences. Takes about a minute.

   - Continue to Phase 2.

## Phase 2: Prerequisites check

Run `bin/check-prereqs.sh` and show the output. This is informational —
don't block setup on soft prereq misses. Only warn if a hard prereq is
missing (exit code 1); in that case, tell the user what to install but
still continue setup since preferences don't depend on tools.

## Phase 3: Collect preferences

Use the `AskUserQuestion` tool to present interactive selection menus.
Batch questions into groups (max 4 per call) to reduce back-and-forth.
If the user selects "Other" on any question, accept their free-text
input and map it to the closest valid value.

### 3.1 Default profile (conversational — too many options for a picker)

Ask conversationally:

> What stack do you work with most often? This sets which profile nyann
> picks when you don't specify one during bootstrap.

List options grouped by language:
- **auto-detect** (default) — nyann inspects the repo each time
- JS/TS: `nextjs-prototype`, `react-vite`, `node-api`, `typescript-library`
- Python: `fastapi-service`, `django-app`, `python-cli`
- Systems: `go-service`, `rust-cli`
- Mobile: `swift-ios`, `kotlin-android`
- Other: `shell-cli`, `default`

If the user says something like "I mostly do Python FastAPI", map to
`fastapi-service`. If they work across multiple stacks, recommend
`auto-detect`.

### 3.2–3.4 First picker batch

After collecting the profile answer, use `AskUserQuestion` with these
three questions in a single call:

**Question 1 — Branching strategy** (header: "Branching"):
- "Auto-detect (Recommended)" — nyann picks based on project size/type
- "GitHub Flow" — simple: main + feature branches
- "GitFlow" — main + develop + feature/release/hotfix branches
- "Trunk-based" — short-lived branches, frequent merges to main

**Question 2 — Commit format** (header: "Commits"):
- "Conventional Commits (Recommended)" — enforces feat:, fix:, etc. in hooks
- "Custom" — no commit format enforcement

**Question 3 — GitHub CLI** (header: "GitHub CLI"):
- Check `command -v gh` first. If gh is NOT installed, skip this
  question and default to no.
- If gh IS installed:
  - "Yes (Recommended)" — enable branch protection and PR helpers
  - "No" — skip all gh-dependent features

### 3.5–3.6 Second picker batch

Use `AskUserQuestion` with these two questions in a single call:

**Question 1 — Documentation storage** (header: "Docs"):
- "Local (Recommended)" — docs/ directory in the repo
- "Obsidian" — route to an Obsidian vault via MCP
- "Notion" — route to Notion via MCP

**Question 2 — Team profile auto-sync** (header: "Team sync"):
- "No (Recommended)" — manual sync only via /nyann:sync-team-profiles
- "Yes" — auto-sync during bootstrap when interval expires

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
