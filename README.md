<p align="center">
  <img src="logo-banner.jpg" alt="nyann — bamboo scaffolding for your codebase" width="100%" />
</p>

# Nyann

> **ငြမ်း** is Burmese for _scaffolding_. Nyann is the Claude Code plugin that picks expert git defaults for your stack — branching, **working hooks** (Husky / pre-commit.com / lefthook), commits, releases, CI, docs — then keeps the repo on those rails through every PR after. Conversational by default; every destructive change is previewed, schema-validated, and reversible.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/thettwe/nyann/actions/workflows/ci.yml/badge.svg)](https://github.com/thettwe/nyann/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/Tests-1318%20passing-brightgreen)](tests/)
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

## What makes it different

- **Working hooks for 26 stacks, not just configs.** nyann installs the right framework — Husky for JS/TS, pre-commit.com for Python, lefthook for Go/Rust, native `.git/hooks` for shell — with hooks that run on day one. No follow-up `husky install` required.
- **Preview before every mutation.** Every destructive path emits a JSON `ActionPlan`, renders a unified diff for merges, and waits for confirmation. The plan is SHA-bound, so the bytes you approve are the bytes that land — no TOCTOU between preview and execute.
- **Reversible.** `bootstrap` and `retrofit` write a `BootRecord` (manifest + pre-state file copies) before mutating. `/nyann:undo-bootstrap` consumes it to restore your repo to its pre-setup state — refusing to clobber files you've edited since.
- **Schema-validated contracts between every script.** All 53 cross-layer JSON shapes (`ActionPlan`, `DriftReport`, `StackDescriptor`, `BootRecord`, …) are locked by JSON Schema. A field rename without a schema bump fails CI. **1318 bats tests** cover the surface.
- **Team-shareable governance.** Profiles are pure data — register a git URL and your team's branching, hooks, conventions, and doc routing sync across every repo automatically. Stale-team-profile detection nudges before the next bootstrap.
- **Health-graded, drift-aware.** `doctor` produces a 0–100 score with per-category deltas and trend sparklines from `memory/health.json`. Inline drift checks at commit / PR / ship time nudge (don't gate) when the repo drifts from its profile; `governance-check.yml` upgrades that to a CI gate when desired.

## Supported stacks

**Working hooks, branching, commits, and docs across 26 stacks.** Nyann detects yours automatically and applies the right profile — branching strategy, commit conventions, language-specific hooks (Husky, pre-commit.com, lefthook, …) wired up to run on day one, and archetype-aware documentation scaffolding. All profiles default to Conventional Commits + GitHub Flow.

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
| Java / Spring Boot | `java-spring-boot` | Checkstyle | - | Maven / Gradle |
| C# / .NET | `dotnet-api` | dotnet format | dotnet format | dotnet |
| PHP / Laravel | `php-laravel` | Pint | Pint | Composer |
| Dart / Flutter | `flutter-app` | dart analyze | dart format | pub |
| Ruby / Rails | `ruby-rails` | RuboCop | RuboCop | Bundler |
| Deno | `deno-app` | deno lint | deno fmt | deno |
| Bun | `bun-app` | ESLint (opt) | Biome / Prettier | bun |
| SvelteKit | `sveltekit-app` | ESLint, svelte-check | Prettier | npm / pnpm / yarn / bun |
| Astro | `astro-site` | ESLint, astro-check | Prettier | npm / pnpm / yarn / bun |
| Nuxt | `nuxt-app` | ESLint | Prettier | npm / pnpm / yarn / bun |
| Elixir / Phoenix | `phoenix-app` | mix credo | mix format | mix |
| NestJS | `nestjs-service` | ESLint | Prettier | npm / pnpm |
| C/C++ CMake | `cpp-cmake` | clang-tidy | clang-format | - |
| Any / Unknown | `default` | - | - | - |

All profiles also include `block-main` (prevent direct commits to main) and `gitleaks` (secret scanning) hooks.

Don't see your stack? You can [create a custom profile](#customizing-profiles) or [learn one from an existing repo](#customizing-profiles).

## Quickstart

**1. Install nyann as a Claude Code plugin.**

Install from the community marketplace (Anthropic-curated, reviewed releases):

```text
claude plugin marketplace add anthropics/claude-plugins-community
claude plugin install nyann@claude-community
```

Or install from the nyann repo directly (latest tag, fastest to update):

```text
/plugin marketplace add thettwe/nyann
/plugin install nyann@nyann-plugins
```

> The community-marketplace listing is SHA-pinned and syncs nightly after Anthropic's review pipeline approves a new version, so it can lag behind by one or more tags. The direct path picks up new tags as soon as you run `/plugin marketplace update`. Use the direct path if you want the newest fixes immediately; use the community path if you prefer to wait for an Anthropic-reviewed release.

For development / hacking on nyann itself, clone directly:

```sh
git clone https://github.com/thettwe/nyann ~/.claude/plugins/nyann
```

**2. Bootstrap a repo.**

Open Claude Code in an empty (or existing) project directory and say:

> "set up this project"

Or use the slash command directly:

> `/nyann:bootstrap`

Claude detects your stack, previews a plan with a unified diff for merge actions, and on confirmation produces:

- Git initialized with the right base branches for the detected branching strategy
- `.gitignore` merged from stack-specific templates (existing user lines preserved — never overwritten)
- **Working git hooks** wired to the right framework: Husky (JS/TS), pre-commit.com (Python), lefthook (Go/Rust), or native `.git/hooks` (shell). Linting, formatting, Conventional-Commits validation, secret scanning, and `block-main` are runnable on day one.
- `docs/` archetype-aware scaffold (api-service / cli-tool / library / web-app / mobile-app / plugin) — architecture, ADR-000, and matching templates
- `memory/` with README plus the BootRecord under `memory/.nyann/bootstraps/<ts>/` so the run is reversible
- `CLAUDE.md` as a router-mode file under the 3 KB soft cap (8 KB hard cap)
- `.editorconfig`, `.github/workflows/ci.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/`, and `CODEOWNERS` (monorepo) when the profile opts in
- GitHub branch + tag protection auto-applied via `gh` if installed and authenticated

Total wall time on a clean directory: **~2 seconds** (excluding `npm install` / `pip install` / etc.).

**3. Keep using nyann.**

You don't need to memorize slash commands. Just describe what you need:

| You say | What happens |
|---|---|
| "commit these changes" | Generates a Conventional Commits message and commits |
| "start a feature branch for login" | Creates a strategy-compliant branch |
| "is this repo healthy?" | Graded health score (0–100), per-category deltas, sparkline trend from history |
| "cut a patch release" | Auto-detects the semver bump from Conventional Commits, regenerates CHANGELOG, tags, optionally creates a GitHub release |
| "pull and rebase" | Syncs upstream changes with conflict guidance |
| "undo that" | Reverses the last commit on a feature branch |
| "undo the bootstrap" | Reverses the last `bootstrap` (or `retrofit`) run from its boot record |
| "open a PR" | Creates a GitHub PR from the current branch |
| "ship it" | Opens a PR and either auto-merges (returns immediately) or polls CI then merges |
| "generate CI for this project" | Writes a GitHub Actions workflow + optional governance gate |

Every skill also has a slash command (`/nyann:commit`, `/nyann:doctor`, etc.) listed in the [full command reference](#skills--commands) below.

## What you get

| Area | What nyann does |
|---|---|
| **Bootstrap** | Stack-detected, schema-validated `ActionPlan` previewed before any write. Per-language working hooks, archetype-aware doc scaffolds, CI workflow, GitHub templates, branch + tag protection, and `.gitignore` merge with diff-preview. Monorepo-aware (pnpm / Turborepo / Nx / Lerna / Cargo workspaces). |
| **Reversibility** | `bootstrap` / `retrofit` write a `BootRecord` (manifest + pre-state file copies) before mutating; `/nyann:undo-bootstrap` reverses the run. Refusal-by-default protects files edited after bootstrap, branches with stacked commits, and HEAD ahead of the bootstrap seed. |
| **Retrofit** | Scoped audit + remediation against a profile. `--scope docs\|hooks\|branching\|gitignore\|editorconfig\|github` lets you fix one category without touching the others. Idempotent — safe to re-run. Boot-record-backed, so it's reversible too. |
| **Doctor** | Read-only hygiene audit with a numerical **health score (0–100)** persisted to `memory/health.json`, rendered as a per-category sparkline trend. Covers hook drift, gitignore, non-Conventional history, broken internal links, doc orphans, doc staleness, CLAUDE.md size budget, and GitHub protection drift. |
| **Commit** | Reads the staged diff, generates a Conventional Commits message scoped to touched workspaces (monorepo), and retries once on hook rejection. Supports `--amend` and `--edit-message`. |
| **Branch** | Creates strategy-compliant branch names off the right base for the active strategy (GitHub Flow / GitFlow / trunk-based). Validates slug; switches to an existing branch if one already matches. |
| **PR** | Opens a GitHub PR with a Conventional-Commits-style title generated from the commit range and a body summarizing the diff. Context-only mode works without `gh`. |
| **Ship** | Combined PR + merge in one step. Default uses GitHub's native auto-merge so the terminal returns immediately with `outcome:"queued"`. `--client-side` polls CI in the foreground and runs `gh pr merge` when checks pass. |
| **Release** | **Auto-detects the next semver bump** from Conventional Commits since the last tag. Generates the CHANGELOG section, optionally bumps profile-declared manifest files (`package.json`, `plugin.json`, `pyproject.toml`, …), creates an annotated tag, pushes a GitHub release. Pre-release support for `-rc.N` / `-beta.N`. CI-gated tagging via `--wait-for-checks`. Monorepo: `--workspace` and `--all-workspaces` for per-workspace versioning with scoped tags (`core@2.1.0`). |
| **Hotfix** | Branch topology for patch releases against a previously tagged version. Creates `release/<major>.<minor>` from the source tag if missing, then `hotfix/<slug>` off it. Pairs with `release` for the actual cut. |
| **PR risk score** | `/nyann:ship` computes a composite risk score (churn × test gap × health delta) and surfaces `low | medium | high` with actionable recommendations before opening the PR. Highlights "many source changes without matching test updates" and hotspot files. |
| **CI generation** | Generates `.github/workflows/ci.yml` matched to your stack and profile (lint + typecheck + test jobs). Optional `governance-check.yml` posts inline PR comments when drift exceeds threshold or health drops below the floor. |
| **GitHub protection** | Audit (`--check`) or apply branch protection, tag rulesets, signing requirements, security settings, and Dependabot config. Output validates against `protection-audit.schema.json` so other tooling can consume it. |
| **Docs routing** | Routes docs to local Markdown, Obsidian (MCP), Notion (MCP), or a per-doc-type split. Standalone re-routing after bootstrap regenerates the scaffold to match. `memory/` stays local. |
| **CLAUDE.md** | Router-mode generation under 3 KB soft / 8 KB hard cap. Standalone regeneration via `gen-claudemd`. **Usage-based optimization** trims sections Claude never references, based on `analytics/claudemd-usage.jsonl`. |
| **Inline drift checks** | Drift detection runs at point-of-use (commit / PR / ship / release) — not on session start. Surfaces broken links, orphans, doc staleness, CLAUDE.md size, and protection drift. Non-blocking nudge by default; CI gate on opt-in. |

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
| `/nyann:undo-bootstrap [--manifest <path>] [--scope <csv>] [--force] [--dry-run]` | Reverse a bootstrap or retrofit run from its BootRecord manifest. |
| `/nyann:cleanup-branches [--yes]` | Prune local branches whose work is merged. |
| `/nyann:gen-ci [--profile <name>]` | Generate GitHub Actions CI workflow. |
| `/nyann:gen-templates [--profile <name>]` | Generate PR + issue templates. |
| `/nyann:gen-claudemd [--profile <name>] [--force]` | Regenerate CLAUDE.md without a full bootstrap. |
| `/nyann:gen-dependency-updater` | Generate profile-aware Dependabot or Renovate config. |
| `/nyann:gen-devcontainer` | Generate profile-aware `.devcontainer/devcontainer.json` for Codespaces. |
| `/nyann:explain-diff` | Translate a drift report into plain-English markdown. |
| `/nyann:gh-protect [--check] [--profile <name>]` | Audit or apply GitHub protection rules. |
| `/nyann:route-docs [--routing <spec>]` | Change doc storage routing + regenerate scaffold. |
| `/nyann:optimize-claudemd [--force]` | Optimize CLAUDE.md based on usage data. |
| `/nyann:record-decision <title>` | Create a numbered ADR. |
| `/nyann:explain-state` | Summarize repo state for handoff. |
| `/nyann:suggest [--profile <name>]` | Suggest profile updates from repo state. |
| `/nyann:diff-profile --left <a> --right <b>` | Structured diff between two profiles. |
| `/nyann:inspect-profile <name>` | Pretty-print a profile. |
| `/nyann:migrate-profile --to <name>` | Switch profile with diff + re-bootstrap. |
| `/nyann:learn-profile [--target <path>] [--name <kebab>]` | Extract a reusable profile from an existing repo. |
| `/nyann:add-team-source --name <n> --url <u>` | Register a team profile repo. |
| `/nyann:sync-team-profiles [--force]` | Sync team profiles from remote. |
| `/nyann:check-prereqs [--json]` | Survey hard + soft prereqs. |
| `/nyann:diagnose [--json]` | Bundle a redacted support snapshot. |

All 35 skills respond to natural language, not just slash commands. See `skills/*/SKILL.md` for trigger-phrase lists. Every skill above also has a `commands/*.md` slash entry — invoke either way.

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
# Register a source — optionally pinned to a tag, SHA, or branch
bin/add-team-source.sh --name our-team \
  --url https://github.com/our-org/nyann-profiles.git \
  --pin-strategy tag --pin-ref v1.0.0

# Sync (shallow clone, respects sync_interval_hours)
bin/sync-team-profiles.sh [--force]

# When pinned: check what would change before accepting an update
bin/sync-team-profiles.sh --check-updates --name our-team
bin/sync-team-profiles.sh --accept-update --name our-team
```

When a team profile updates upstream, nyann checks for staleness at point-of-use (during bootstrap and profile migration) and prompts you to sync before proceeding. **SHA and tag pinning** (v1.11.0) keep the team source on a known-good revision; updates require explicit `--accept-update` and surface a changelog of what changed.

### Profile composition (`extends`)

Avoid copy-paste between similar profiles. A child profile can inherit from a parent via `"extends"`:

```json
{
  "name": "my-react-vite",
  "extends": "react-vite",
  "branching": { "scopes": ["api", "web"] }
}
```

Deep merge semantics: scalars and objects merge recursively (child wins), arrays replace entirely, `null` removes a parent's field. Max chain depth: 3. Circular references are rejected. Namespaced `team/name` form is supported for team-source parents.

## Project Memory

nyann scaffolds and maintains your project's **Project Memory** — a documentation layer designed for AI agents to retrieve, sized to fit their context, and kept in sync as your code evolves.

```
   CLAUDE.md  ──→  docs/        (durable Project Memory)
       │      ──→  memory/      (ephemeral team scratch)
       │
       └─ router-mode (≤ 3 KB), points into both.
```

Five properties define it:

1. **AI-retrieval-first** — bounded scope per doc, predictable structure, decision rationale captured.
2. **Size-budgeted** — docs fit in context windows. CLAUDE.md is router-mode (≤3 KB soft cap), not a content dump.
3. **Drift-aware** — broken links, orphans, and staleness surfaced automatically by `doctor` and CI.
4. **Storage-agnostic** — local Markdown, Obsidian (MCP), or Notion (MCP). Equal citizens.
5. **Dual-audience** — high-signal structure works for AI agents AND humans reading reference docs.

See [`docs/principles/documentation.md`](docs/principles/documentation.md) for the full definition.

### Storage routing

By default `CLAUDE.md` links to local `docs/` and `memory/`.

When Claude Code has an Obsidian or Notion MCP configured, nyann asks where each doc type should live:

```text
adrs:obsidian, research:local, architecture:local
```

`memory/` is **always** local — it's the ephemeral team-shared scratch layer, distinct from Project Memory itself.

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

## Repository layout

```
bin/                   # 76 top-level shell scripts + 25 extracted modules + 1 python helper
commands/              # 35 Claude Code slash-command registrations
evals/                 # 24 skill-level trigger + output-quality specs
hooks/                 # Claude Code PreToolUse block-main hook
profiles/              # 26 starter profiles (+ _schema.json)
schemas/               # 53 JSON Schemas for every exchanged shape
skills/                # 35 skills (SKILL.md, optionally with references/ and scripts/)
templates/             # gitignore, pre-commit configs, husky, docs, CI, memory
monitors/              # Monitor manifest (monitors.json, currently empty)
tests/                 # 1318 bats tests + fixtures
```

## Recent changes

See [`CHANGELOG.md`](CHANGELOG.md) for the full release history. Most recent: **v1.11.0** ships profile composition (`extends`), monorepo workspace releases, PR risk scoring in `/nyann:ship`, team profile pinning (SHA + tag), and CODEOWNERS generation from git history. Plus an orchestrator refactor that splits the three biggest monoliths (release, gh-integration, detect-stack) into per-feature modules.

---

Issues and feature requests: <https://github.com/thettwe/nyann/issues>.
