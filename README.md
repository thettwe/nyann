# Nyann

> **ငြမ်း** is Burmese for _scaffolding_. Nyann is a Claude Code plugin that sets up and maintains project governance: git workflow, hooks, branching, commits, releases, CI, docs routing, and health monitoring. From first init through every PR after.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/thettwe/nyann/actions/workflows/ci.yml/badge.svg)](https://github.com/thettwe/nyann/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/Tests-711%20passing-brightgreen)](tests/)
[![Release](https://img.shields.io/github/v/release/thettwe/nyann)](https://github.com/thettwe/nyann/releases)

## Is nyann for you?

**Use nyann when:**

- You start new projects more than once a month.
- You maintain multiple repos and want consistent hygiene across all of them.
- You use Claude Code and want git + hooks + docs setup to be conversational.
- You lead a small team and want shared conventions via profiles.

**Skip nyann when:**

- You start maybe one project a year. The setup time to learn nyann outweighs what it saves.
- You have mature internal scaffolding you're happy with.
- You want a code generator (nyann does not scaffold application code; that's `create-next-app` / `cookiecutter` territory).

## Supported stacks

Nyann detects your stack automatically and applies the right profile. Every profile includes branching strategy, commit conventions, and documentation scaffolding. All profiles use Conventional Commits and GitHub Flow by default.

| Stack | Profile | Linting | Formatting | Package Manager |
|---|---|---|---|---|
| TypeScript / Next.js | `nextjs-prototype` | ESLint | Prettier | npm / pnpm / yarn / bun |
| TypeScript Library | `typescript-library` | ESLint, tsc | Prettier | npm / pnpm / yarn / bun |
| React + Vite | `react-vite` | ESLint | Prettier | npm / pnpm / yarn / bun |
| Node.js API | `node-api` | ESLint | Prettier | npm / pnpm / yarn / bun |
| Python CLI | `python-cli` | Ruff | Ruff | uv |
| Django | `django-app` | Ruff | Ruff | uv |
| FastAPI | `fastapi-service` | Ruff | Ruff | uv |
| Go | `go-service` | go vet, golangci-lint | gofmt | go |
| Rust | `rust-cli` | Clippy | rustfmt | cargo |
| Swift / iOS | `swift-ios` | SwiftLint | SwiftFormat | SPM |
| Kotlin / Android | `kotlin-android` | detekt | ktlint | Gradle |
| Shell / Bash | `shell-cli` | ShellCheck | shfmt | - |
| Any / Unknown | `default` | - | - | - |

All profiles also include `block-main` (prevent direct commits to main) and `gitleaks` (secret scanning) hooks.

Don't see your stack? You can [create a custom profile](#customizing-profiles) or [learn one from an existing repo](#customizing-profiles).

## Quickstart

**1. Install nyann as a Claude Code plugin.**

The repo ships a `.claude-plugin/marketplace.json` so the plugin can be installed through Claude Code's marketplace flow:

```text
/plugin marketplace add thettwe/nyann
/plugin install nyann@nyann
```

Or, for development / hacking on nyann itself, clone directly:

```sh
git clone https://github.com/thettwe/nyann ~/.claude/plugins/nyann
```

**2. Bootstrap a repo.**

Open Claude Code in an empty (or existing) project directory and say:

> "set up this project"

Or use the slash command directly:

> `/nyann:bootstrap`

Claude detects your stack, previews a plan, and on confirmation produces:

- Initialized git with correct base branches
- `.gitignore` assembled from stack-aware templates
- Git hooks (linting, formatting, Conventional Commits, secret scanning, per stack)
- `docs/` (architecture, ADR-000 + template) and `memory/` with README
- `CLAUDE.md` as a compact router under 3 KB
- `.editorconfig` if the profile declares it

Total wall time on a clean directory: **~2 seconds** (excluding `npm install` / `pip install` / etc.).

**3. Keep using nyann.**

You don't need to memorize slash commands. Just describe what you need:

| You say | What happens |
|---|---|
| "commit these changes" | Generates a Conventional Commits message and commits |
| "start a feature branch for login" | Creates a strategy-compliant branch |
| "is this repo healthy?" | Runs a full hygiene and docs audit |
| "cut a patch release" | Bumps version, updates changelog, tags |
| "pull and rebase" | Syncs upstream changes with conflict guidance |
| "undo that" | Reverses the last commit or bootstrap |
| "open a PR" | Creates a GitHub PR from the current branch |
| "ship it" | Opens a PR and merges when CI goes green |
| "generate CI for this project" | Writes a GitHub Actions workflow |

Every skill also has a slash command (`/nyann:commit`, `/nyann:doctor`, etc.) listed in the [full command reference](#skills--commands) below.

## What you get

| Area | What nyann does |
|---|---|
| **Bootstrap** | Detects stack, picks branching strategy, installs hooks, scaffolds docs + memory, writes CLAUDE.md. Monorepo-aware (pnpm / Turborepo / Nx / Lerna / Cargo workspaces). |
| **Retrofit** | Audits an existing repo against a profile and fixes what's drifted: missing hooks, incomplete gitignore, documentation gaps. |
| **Doctor** | Read-only hygiene audit. Surfaces missing hooks, bad gitignore, non-Conventional history, broken links, orphans, CLAUDE.md overruns, GitHub protection drift. |
| **Commit** | Reads the staged diff, generates a Conventional Commits message, retries once on hook rejection. |
| **Branch** | Creates strategy-compliant branch names off the right base. Validates slug; switches to existing branches. |
| **PR** | Opens a GitHub PR with generated title and body. Context-only mode works without `gh`. |
| **Ship** | Combined PR + merge in one step. Auto-merge (returns immediately) or client-side (polls CI, merges when green). |
| **Release** | Bumps version, generates changelog from Conventional Commits, creates an annotated tag. CI-gated tagging via `--wait-for-checks`. |
| **Hotfix** | Branch-topology setup for patch releases against a previously tagged version. |
| **CI generation** | Generates a GitHub Actions workflow matching your stack and profile. |
| **GitHub protection** | Audits or applies branch protection, tag rulesets, signing requirements, and repo settings. |
| **Docs routing** | Routes docs to local, Obsidian, or Notion. Memory is always local. Standalone re-routing after bootstrap. |
| **CLAUDE.md** | Router-mode generation (3 KB soft / 8 KB hard cap), standalone regeneration, and usage-based optimization. |
| **Inline drift checks** | Drift detection runs at point-of-use (commit, PR, ship, release) — not on session start. Non-blocking nudge, not a gate. |

## Skills & commands

| Command | Purpose |
|---|---|
| `/nyann:setup` | First-run onboarding + preferences. |
| `/nyann:bootstrap [--profile <name>]` | Full setup flow. |
| `/nyann:retrofit [--profile <name>] [--json]` | Audit drift + offer remediation. |
| `/nyann:doctor [--profile <name>] [--json]` | Read-only hygiene + docs audit. |
| `/nyann:commit [--amend \| --no-retry \| --edit-message]` | Generate + commit a Conventional Commits message. |
| `/nyann:branch <purpose> <slug-or-version>` | Strategy-compliant branch creation. |
| `/nyann:pr [--draft] [--auto-merge]` | Open a GitHub PR from current branch. |
| `/nyann:ship [--client-side] [--merge-strategy s]` | Combined PR + auto-merge (or poll-and-merge). |
| `/nyann:wait-for-pr-checks [--pr <n>] [--timeout <s>]` | Poll a PR's checks until pass / fail / timeout. |
| `/nyann:release --version <x.y.z>` | Generate changelog, commit, and tag. |
| `/nyann:hotfix --from <tag> --slug <slug>` | Set up hotfix branch topology. |
| `/nyann:sync` | Pull + rebase with conflict guidance. |
| `/nyann:undo [--hard]` | Reverse last commit on a feature branch. |
| `/nyann:cleanup-branches [--yes]` | Prune local branches whose work is merged. |
| `/nyann:gen-ci [--profile <name>]` | Generate GitHub Actions CI workflow. |
| `/nyann:gen-templates [--profile <name>]` | Generate PR + issue templates. |
| `/nyann:gen-claudemd [--profile <name>] [--force]` | Regenerate CLAUDE.md without a full bootstrap. |
| `/nyann:gh-protect [--check] [--profile <name>]` | Audit or apply GitHub protection rules. |
| `/nyann:route-docs [--routing <spec>]` | Change doc storage routing + regenerate scaffold. |
| `/nyann:optimize-claudemd [--force]` | Optimize CLAUDE.md based on usage data. |
| `/nyann:record-decision <title>` | Create a numbered ADR. |
| `/nyann:explain-state` | Summarize repo state for handoff. |
| `/nyann:suggest [--profile <name>]` | Suggest profile updates from repo state. |
| `/nyann:inspect-profile <name>` | Pretty-print a profile. |
| `/nyann:migrate-profile --to <name>` | Switch profile with diff + re-bootstrap. |
| `/nyann:learn-profile [--target <path>] [--name <kebab>]` | Extract a reusable profile from an existing repo. |
| `/nyann:add-team-source --name <n> --url <u>` | Register a team profile repo. |
| `/nyann:sync-team-profiles [--force]` | Sync team profiles from remote. |
| `/nyann:check-prereqs [--json]` | Survey hard + soft prereqs. |
| `/nyann:diagnose [--json]` | Bundle a redacted support snapshot. |

All 30 skills respond to natural language, not just slash commands. See `skills/*/SKILL.md` for trigger-phrase lists. Every skill above also has a `commands/*.md` slash entry — invoke either way.

## Profiles

### Customizing profiles

Nyann picks the right profile automatically. If the starter profiles don't fit, you have two options:

**Learn from an existing repo.** If you already have a well-configured project, nyann can extract a reusable profile from it:

```sh
bin/learn-profile.sh --target ~/projects/my-good-app --name good-app
```

This infers stack, hooks, branching, and conventions from the repo's files and last 50 commits.

**Inspect any profile.** To see what a profile contains before using it:

```sh
bin/inspect-profile.sh nextjs-prototype
```

### Profile precedence

When multiple profiles exist with the same name, the most specific one wins:

1. `~/.claude/nyann/profiles/<name>.json` user profiles
2. `~/.claude/nyann/cache/<source>/.../<name>.json` team profiles (synced from a git URL)
3. `<plugin>/profiles/<name>.json` starter profiles

A namespaced name like `our-team/frontend-baseline` bypasses user shadowing.

### Team profiles

Share conventions across a team by syncing profiles from a git repo:

```sh
# Register a source
bin/add-team-source.sh --name our-team --url https://github.com/our-org/nyann-profiles.git

# Sync (shallow clone, respects sync_interval_hours)
bin/sync-team-profiles.sh [--force]
```

When a team profile updates upstream, nyann checks for staleness at point-of-use (during bootstrap and profile migration) and prompts you to sync before proceeding.

## Documentation routing

By default `CLAUDE.md` links to local `docs/architecture.md`, `docs/decisions/`, and `memory/`.

When Claude Code has an Obsidian or Notion MCP configured, nyann asks where each doc type should live:

```text
adrs:obsidian, research:local, architecture:local
```

`memory/` is **always** local.

## Prereqs

Run `/nyann:check-prereqs` (or `bin/check-prereqs.sh`) for a live inventory.

**Hard** (required):

- `git`
- `jq` (`brew install jq` / `apt install jq`)
- `bash` 3.2+ (macOS default is fine)

**Soft** (feature-gated; nyann skips with a reason when missing):

| Feature | Needs |
|---|---|
| JS/TS hooks | `node` + `npm` / `pnpm` / `yarn` / `bun` |
| Python hooks | `python3` + `pre-commit` (or `uv` / `uvx`) |
| Go hooks | `go` |
| Rust hooks | `cargo` |
| Swift hooks | `swiftlint`, `swiftformat` |
| Kotlin hooks | `ktlint`, `detekt` |
| Shell hooks | `shellcheck`, `shfmt` |
| Secret scanning | `gitleaks` |
| Branch protection | `gh` with `gh auth status` green |
| Schema validation | `uv` (provides `uvx check-jsonschema`) or `check-jsonschema` |
| Dev loop | `shellcheck`, `bats-core` |

Nyann never prompts for credentials. `gh auth status` is a passive read; missing auth surfaces as a skip, not a prompt.

## Roadmap

### Shipped in v1.0.0

- [x] 30 skills with natural-language triggers and slash commands
- [x] 13 starter profiles covering JS/TS, Python, Go, Rust, Swift, Kotlin, Shell
- [x] Stack detection (frameworks, monorepos, polyglot)
- [x] Hook installation (core + per-stack + pre-push)
- [x] Branching strategy recommender (GitHub Flow / GitFlow / trunk-based)
- [x] GitHub branch protection, tag rulesets, signing, and repo settings audit + apply
- [x] Combined PR + merge (`/nyann:ship`) with auto-merge and client-side modes
- [x] Release with CI-gated tagging (`--wait-for-checks`)
- [x] Doc routing (local / Obsidian / Notion / split)
- [x] CLAUDE.md generation, standalone regeneration, and usage-based optimization
- [x] Team profile sync with drift detection
- [x] 38 JSON schemas locking every cross-layer contract
- [x] 711 bats tests, shellcheck, SKILL.md length enforcement
- [x] Preview-before-mutate with SHA256 integrity binding

### Planned

- [ ] **More stacks:** Flutter, Java, C#/.NET, Ruby on Rails, Elixir/Phoenix
- [ ] **GitLab and Bitbucket** support for remote integration (currently GitHub only)
- [ ] **Windows support:** `.ps1` hook variants for native Windows workflows
- [ ] **ActionPlan `remote[]` dispatcher** for server-side automation beyond branch protection

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Repository layout

```
bin/                   # 58 shell scripts (orchestrators + subsystems)
commands/              # 30 Claude Code slash-command registrations
evals/                 # 23 skill-level trigger + output-quality specs
hooks/                 # Claude Code PreToolUse block-main hook
profiles/              # 13 starter profiles (+ _schema.json)
schemas/               # 38 JSON Schemas for every exchanged shape
skills/                # 30 skills (SKILL.md, optionally with references/ and scripts/)
templates/             # gitignore, pre-commit configs, husky, docs, memory
monitors/              # Monitor manifest (monitors.json, currently empty)
tests/                 # 711 bats tests + fixtures
```

---

Issues and feature requests: <https://github.com/thettwe/nyann/issues>.
