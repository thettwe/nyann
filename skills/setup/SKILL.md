---
name: setup
description: >
  First-run onboarding for nyann. Creates the user config directory,
  collects preferences through AskUserQuestion interactive pickers, and
  writes ~/.claude/nyann/preferences.json.
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

> **CRITICAL**: This skill uses the `AskUserQuestion` tool for ALL user
> choices. **NEVER ask questions as plain text.** Every user choice goes
> through `AskUserQuestion` with the exact JSON shown below.

**Script paths:** nyann is a Claude Code plugin, NOT a CLI tool. Do NOT
search for it via `which`, `npm list`, `pip list`, or `brew list`. All
scripts are at the plugin root. Determine the plugin root from this
SKILL.md's path (`<plugin_root>/skills/setup/SKILL.md`) — the scripts
are at `<plugin_root>/bin/`. Use `bash <plugin_root>/bin/<script>` for
all commands below.

Re-runnable: if preferences already exist, show current values and
offer to update them.

## Step 1: Status + prereqs (parallel, one turn)

Run both commands **in parallel** (single tool-call turn):

- `bash <plugin_root>/bin/setup.sh --check --json`
- `bash <plugin_root>/bin/check-prereqs.sh --json`

**Do NOT show the raw JSON to the user.** Parse the `prereqs` array
and build **separate small tables by category**. Use pipe-delimited
markdown (NO box-drawing characters, NO manual padding). Shorten
version strings (e.g., `git version 2.50.1 (Apple Git-155)` → `2.50.1`).

Example output:

```
**Required**

| Tool | Status | Version |
|---|---|---|
| git | ok | 2.50.1 |
| jq | ok | 1.7.1 |
| bash | ok | 3.2.57 |

**JS / TS**

| Tool | Status | Version |
|---|---|---|
| node | ok | v25.9.0 |
| pnpm | ok | 10.13.1 |

**Python**

| Tool | Status | Version |
|---|---|---|
| python3 | ok | 3.14.4 |
| pre-commit | ok | 4.6.0 |
| uv | ok | 0.9.15 |

**Other**

| Tool | Status | Version |
|---|---|---|
| go | ok | 1.26.2 |
| cargo | missing | https://rustup.rs |
| gh | ok | 2.83.1 |
| gitleaks | ok | 8.30.1 |
| shellcheck | ok | 0.11.0 |

All hard prerequisites satisfied.
```

Group tools by: **Required** (kind=hard), **JS / TS** (node, npm,
pnpm, yarn, bun), **Python** (python3, pre-commit, uv),
**Other** (everything else). Skip empty groups. For missing tools,
show the `hint` field instead of a version.

Then display a single combined message:

- If `status == "configured"`: show current preferences as a table,
  then ask "Want to update any of these?" If no, skip to Step 4.
- If `status == "not_configured"`: show the welcome greeting, then
  the prereqs table, then continue to Step 2 immediately:

  > **Welcome to nyann!** Let's get you set up.

Continue to Step 2 — do NOT pause for prereqs.

## Step 2: Quick or custom setup

**Call `AskUserQuestion`** — this is the first and possibly only picker:

```json
{
  "questions": [
    {
      "question": "How would you like to configure nyann?",
      "header": "Setup",
      "multiSelect": false,
      "options": [
        { "label": "Quick setup (Recommended)", "description": "Use smart defaults: auto-detect stack & branching, conventional commits, GitHub CLI enabled, local docs" },
        { "label": "Customize", "description": "Choose each setting individually" }
      ]
    }
  ]
}
```

- **Quick setup** → skip to Step 3 with all defaults.
- **Customize** → continue to Step 2b.

### Step 2b: Custom preferences (only if Customize)

Check `command -v gh` first. If gh is NOT installed, skip the GitHub CLI
question and default to `--no-gh-integration`.

**Call `AskUserQuestion`** with up to 4 questions:

```json
{
  "questions": [
    {
      "question": "What stack do you work with most often?",
      "header": "Stack",
      "multiSelect": false,
      "options": [
        { "label": "Auto-detect (Recommended)", "description": "nyann inspects the repo each time and picks the right profile" },
        { "label": "Next.js", "description": "nextjs-prototype profile — React + Next.js projects" },
        { "label": "FastAPI", "description": "fastapi-service profile — Python FastAPI services" },
        { "label": "Python CLI", "description": "python-cli profile — command-line Python tools" }
      ]
    },
    {
      "question": "Which branching strategy should nyann default to?",
      "header": "Branching",
      "multiSelect": false,
      "options": [
        { "label": "Auto-detect (Recommended)", "description": "nyann picks based on project size and type" },
        { "label": "GitHub Flow", "description": "Simple: main + feature branches" },
        { "label": "GitFlow", "description": "main + develop + feature/release/hotfix branches" },
        { "label": "Trunk-based", "description": "Short-lived branches, frequent merges to main" }
      ]
    },
    {
      "question": "Which commit message format should nyann enforce?",
      "header": "Commits",
      "multiSelect": false,
      "options": [
        { "label": "Conventional Commits (Recommended)", "description": "Enforces feat:, fix:, chore: etc. in commit hooks" },
        { "label": "Custom", "description": "No commit format enforcement" }
      ]
    },
    {
      "question": "Enable GitHub CLI integration for branch protection and PR helpers?",
      "header": "GitHub CLI",
      "multiSelect": false,
      "options": [
        { "label": "Yes (Recommended)", "description": "Enable branch protection audit and PR helpers via gh" },
        { "label": "No", "description": "Skip all gh-dependent features" }
      ]
    }
  ]
}
```

Docs and team sync use defaults (`local`, `no`). These are rarely
changed and not worth an extra picker round-trip. Users who need
non-default values can re-run `/nyann:setup` or use
`/nyann:route-docs`.

## Step 3: Write preferences

### Value mapping

| Picker label | Flag | Value |
|---|---|---|
| Auto-detect (Stack) | `--default-profile` | `auto-detect` |
| Next.js | `--default-profile` | `nextjs-prototype` |
| FastAPI | `--default-profile` | `fastapi-service` |
| Python CLI | `--default-profile` | `python-cli` |
| Auto-detect (Branching) | `--branching-strategy` | `auto-detect` |
| GitHub Flow | `--branching-strategy` | `github-flow` |
| GitFlow | `--branching-strategy` | `gitflow` |
| Trunk-based | `--branching-strategy` | `trunk-based` |
| Conventional Commits (Recommended) | `--commit-format` | `conventional-commits` |
| Custom | `--commit-format` | `custom` |
| Yes (GitHub CLI) | `--gh-integration` | _(flag only)_ |
| No (GitHub CLI) | `--no-gh-integration` | _(flag only)_ |

If user picked "Other" for Stack, map to the matching profile name
(`react-vite`, `node-api`, `typescript-library`, `django-app`,
`go-service`, `rust-cli`, `swift-ios`, `kotlin-android`, `shell-cli`,
`default`).

**Use the exact values above.** Never abbreviate (`conventional-commits`
not `conventional`).

### Quick setup defaults

```
bash <plugin_root>/bin/setup.sh \
  --default-profile auto-detect \
  --branching-strategy auto-detect \
  --commit-format conventional-commits \
  --gh-integration \
  --documentation-storage local \
  --no-auto-sync-team-profiles
```

If `gh` is not installed, use `--no-gh-integration` instead.

### Custom setup

```
bash <plugin_root>/bin/setup.sh \
  --default-profile <mapped-value> \
  --branching-strategy <mapped-value> \
  --commit-format <mapped-value> \
  --gh-integration | --no-gh-integration \
  --documentation-storage local \
  --no-auto-sync-team-profiles
```

## Step 4: Summary

Show a rich summary table and a clear next action:

```
**nyann configured!**

| Setting    | Value                |
|------------|----------------------|
| Stack      | auto-detect          |
| Branching  | auto-detect          |
| Commits    | conventional-commits |
| GitHub CLI | enabled              |
| Docs       | local                |
| Team sync  | off                  |

**Next:** run `/nyann:bootstrap` in a project to set it up.
Run `/nyann:setup` anytime to change these.
```

## When to hand off

- "Now bootstrap this repo" → `bootstrap-project` skill.
- "Check my tools" → `check-prereqs` skill.
- "Add team profiles" → `add-team-source` skill.
