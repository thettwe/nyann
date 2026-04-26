# Changelog

All notable changes to **nyann** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-04-26

First public release. Nyann is a Claude Code plugin for project governance —
bootstrap, audit, commit, branch, PR, release, and health monitoring across
13 stack profiles.

### Skills (30)

- **bootstrap** — stack-aware project setup (hooks, branching, docs, CI) in ~2s
- **retrofit** — audit an existing repo against a profile, fix drift
- **doctor** — read-only hygiene + docs + protection audit
- **commit** — Conventional Commits message generation with hook retry
- **branch** — strategy-compliant branch creation with slug validation
- **pr** — GitHub PR creation with context-only mode (works without `gh`)
- **ship** — combined PR + merge: auto-merge (instant return) or client-side (poll-and-merge)
- **wait-for-pr-checks** — poll CI status until pass/fail/timeout
- **release** — changelog generation, version bump, tag creation with `--wait-for-checks` CI gating
- **hotfix** — branch-topology setup for patch releases against a tagged version
- **sync** — pull + rebase with conflict guidance
- **undo** — safely reverse recent commits on feature branches
- **cleanup-branches** — prune local branches whose work is merged
- **gen-ci** — generate GitHub Actions workflow from profile + stack
- **gen-templates** — scaffold PR + issue templates
- **gen-claudemd** — standalone CLAUDE.md regeneration without full bootstrap
- **gh-protect** — audit or apply GitHub branch protection, tag rulesets, signing, repo settings
- **route-docs** — change doc storage routing (local/Obsidian/Notion) post-bootstrap
- **optimize-claudemd** — usage-based CLAUDE.md section promotion/demotion
- **record-decision** — create numbered ADR
- **explain-state** — summarize repo state for handoff
- **suggest** — recommend profile updates from repo analysis
- **inspect-profile** — pretty-print a profile
- **migrate-profile** — switch profile with diff + re-bootstrap
- **learn-profile** — extract a reusable profile from an existing repo
- **add-team-source** — register a team profile repo
- **sync-team-profiles** — sync team profiles from remote
- **check-prereqs** — survey hard + soft prerequisites
- **diagnose** — bundle a redacted support snapshot
- **setup** — first-run onboarding + preferences

### Profiles (13)

`default`, `nextjs-prototype`, `typescript-library`, `react-vite`, `node-api`,
`python-cli`, `django-app`, `fastapi-service`, `go-service`, `rust-cli`,
`swift-ios`, `kotlin-android`, `shell-cli`.

Three-tier resolution: user > team > starter. Profiles are data, never code
(strict JSON Schema validation, no eval, no embedded scripts).

### Hooks

- Language-agnostic core: commit-msg, block-main, gitleaks
- Stack-specific: husky/lint-staged (JS/TS), pre-commit.com/ruff (Python),
  golangci-lint (Go), clippy/rustfmt (Rust), SwiftLint/SwiftFormat (Swift),
  ktlint/detekt (Kotlin), ShellCheck/shfmt (Shell)
- Pre-push hooks wired from `profile.hooks.pre_push[]`
- Two-phase commit (assemble then mv) prevents half-installed state
- User hooks merged via exec-chain, surviving re-installs

### Branching & protection

- Strategy recommender: GitHub Flow / GitFlow / trunk-based
- Branch protection audit + apply via `gh api` (best-effort, never downgrades)
- Tag rulesets, commit/tag signing posture, repo settings audit
- Stale/merged branch detection integrated with doctor

### Documentation & CLAUDE.md

- Router-mode CLAUDE.md (3 KB soft / 8 KB hard cap) with marker-bounded regeneration
- Doc routing: local / Obsidian / Notion / per-type split (`memory/` always local)
- Link checker, orphan detector, architecture + ADR + PRD templates

### CI & GitHub

- GitHub Actions workflow generation from profile + stack
- PR + issue template scaffolding
- CODEOWNERS generation for monorepos
- Pinned action SHAs, least-privilege permissions

### Architecture

- 4-layer design: skill → orchestrator → subsystem → data+templates
- 38 JSON Schemas locking every cross-layer contract
- Preview-before-mutate with SHA256 integrity binding
- All `gh` integration is best-effort (soft-skip when missing/unauthed)

### Quality

- 711 bats tests
- ShellCheck + SKILL.md length enforcement
- 23 eval specs for trigger discrimination + output quality
- Public-surface count locks (skills, commands, profiles, schemas)

[1.0.0]: https://github.com/thettwe/nyann/releases/tag/v1.0.0
