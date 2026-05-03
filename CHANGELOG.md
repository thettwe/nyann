# Changelog

All notable changes to **nyann** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.5.0] - 2026-05-03

### Added

- **`bin/release.sh --bump-manifests`** — profile-driven manifest version bumps. When the active profile declares `release.bump_files[]`, every listed file is rewritten to `--version` in the same release commit as `CHANGELOG.md`. Three formats supported: `json-version-key` (uses `jq` against a configured key path, e.g. `.version` or `.plugins[0].version`), `toml-version-key` (sed-rewrites a single-line `version = "..."` within a named section like `[project]` or `[package]`), and `script` (escape hatch — runs a user-provided shell command with `$NEW_VERSION` exported, cwd is the repo root). Idempotent: a re-run against an already-bumped file emits `action:"unchanged"` instead of mutating again. Mutually exclusive with `--strategy manual` (no commit for the bumps to land in).
- **`bin/release.sh --gh-release`** — creates a GitHub release attached to the just-pushed tag with the rendered CHANGELOG block as `--notes-file`. Auto-passes `--prerelease` when the version has a SemVer suffix (`-rc.N`, `-beta.N`). Soft-skips when `gh` is missing or unauthenticated (per nyann's gh-integration convention) and surfaces a manual recovery command in `next_steps[]`. Requires `--push` (the GH release attaches to the pushed tag); without `--push` the script dies up-front with a clear error.
- **`profile.release.bump_files[]`** — new schema field. Each entry is `{path, format, key|section|command}`. Path is repo-relative and validated against `path_under_target` at runtime. Schema regex permits leading `.` so dotfile-prefixed paths like `.claude-plugin/plugin.json` work; `..` traversal is blocked at runtime, not in the regex.
- **`ReleaseSuccess.bumped_files[]`** + **`ReleaseSuccess.gh_release`** — output schema additions emitted only when the corresponding flag was active. `bumped_files[]` records each declared file with `from_version` + `action`. `gh_release` carries `outcome` (`created`/`skipped`/`failed`), `url` on success, `prerelease`, and `error`/`skipped_reason` on the unhappy paths.
- **`profiles/default.json`** — declares `release.bump_files[]` for `.claude-plugin/plugin.json` (`.version` key) and `.claude-plugin/marketplace.json` (`.plugins[0].version` key), so nyann itself dogfoods the new flags.
- **`skills/release/SKILL.md`** — new section 5.1 documenting when to default `--bump-manifests` and `--gh-release` based on profile + user signals. Output interpretation in section 6 covers the new fields.
- **`docs/proposals/v1.5.0-release-automation.md`** — design doc captured before implementation. Documents the problem (six manual release steps, marketplace.json staleness empirical proof), goals/non-goals, schema additions, three-phase rollout, four open questions resolved during the cut, and the acceptance-criteria checklist.

### Changed

- **`bin/release.sh` accepts `--profile <path>`** so callers (skills, CI) that already have the resolved profile snapshot can skip the `load-profile.sh` round-trip during `--bump-manifests`.

## [1.4.0] - 2026-05-03

### Changed

- **Doctor text mode: single drift pass** — doctor.sh now loads the profile once and calls `compute-drift.sh` directly instead of invoking `retrofit.sh` twice (once for JSON, once for text); eliminates redundant profile validation and duplicate documentation-subsystem execution (~50% faster doctor in text mode)
- **Parallel documentation subsystems** — `compute-drift.sh` runs `check-claude-md-size`, `check-links`, `find-orphans`, and `check-staleness` in parallel using per-subsystem output files instead of sequential shared-file appends; estimated 40–60% wall-clock reduction for repos with non-trivial `docs/` trees
- **Single-pass extension counting** — `detect-stack.sh` extension-count fallback uses one `find | awk` pass instead of 13 separate `find` invocations (one per language); same tree traversal, 13× fewer processes
- **Single-pass CLAUDE.md hints** — `detect_claudemd_hints` uses a single `awk` pass instead of 14+ separate `grep -Eiq` invocations
- **Batch profile scoring** — `suggest-profile.sh` scores all profiles in a single `jq` invocation using `inputs` instead of spawning 3+ `jq` subprocesses per profile (~108 `jq` forks → 1 for 18 profiles)
- **Single-pass stale-branch detection** — `check-stale-branches.sh` uses `git branch --merged` once instead of per-branch `git merge-base --is-ancestor` calls; bash 3.2 compatible (no associative arrays)
- **Session-check caching** — `session-check.sh` caches stale-branch results keyed by HEAD SHA with 60s TTL so back-to-back skill invocations (commit → pr → ship) skip redundant branch classification
- **Single jq for workspace lint-staged config** — `install-hooks.sh` `build_workspace_lint_staged` replaced per-workspace multi-`jq` loop (~35 forks for 5 workspaces) with one `jq` program
- **Bash-native path validation** — `nyann::path_under_target` in `_lib.sh` uses `cd + pwd -P` and lexical `..` normalization instead of spawning a Python subprocess per path; eliminates all python3 dependencies from path validation
- **Starter profile validation sentinel** — `load-profile.sh` skips `validate-profile.sh` (uvx/check-jsonschema subprocess) for starter profiles when a version sentinel matches the current plugin version; user and team profiles still validate on every load
- **Stack passthrough for suggest-profile** — `suggest-profile.sh` accepts `--stack <file>` to reuse a pre-computed StackDescriptor; bootstrap skill updated to pass step-1 detection results, avoiding a redundant `detect-stack.sh` call
- **Batch link-check** — `check-links.sh` extracts links from every source file in one `python3` call (vs one per source) and accumulates broken / skipped / mcp results into TSV files reduced to JSON in three trailing `jq` calls (vs `jq` per link); ~200 `jq` forks + ~150 `python3` forks eliminated per audit on a doc-heavy repo. Per-link `python3 -c` realpath replaced by `nyann::path_under_target`
- **Batch find-orphans** — `find-orphans.sh` passes search terms via a US-separated `awk -v` instead of a per-iteration `mktemp` + `awk` + `grep -Fxq` pipeline; orphan rows accumulate as TSV and one trailing `jq` builds the array. ~90 forks eliminated on a 30-doc audit
- **Batch check-staleness** — `check-staleness.sh` accumulates stale entries as TSV and converts to JSON in one trailing `jq` instead of forking `jq` per stale file
- **Single-pass release commit collection + render** — `release.sh` parses commits into TSV in the loop and converts to JSON once; `render_changelog_block` builds the entire CHANGELOG section (header + breaking + 9 type sections + Other) in one `jq` program instead of ~12 separate `jq` invocations over the same `commits_json`
- **Batch sync-team-profiles source unpacking** — `sync-team-profiles.sh` reads source `name`/`url`/`ref`/`interval`/`last_synced_at` via one `jq | @tsv` pass instead of 5 individual `jq` forks per source
- **Shared pre-commit YAML merger** — duplicate inline Python merger in `install-hooks.sh` (Python phase + shared go/rust installer) extracted into `bin/_precommit-merge.py`; same fork cost, single source of truth
- **Batch gen-claudemd workspace table** — `gen-claudemd.sh` emits one `jq | @tsv` row per workspace and decorates in bash; replaces the previous 5-`jq`-per-workspace pattern (~50 `jq` forks → 1 for a 10-workspace monorepo)
- **Batch switch-profile field extractions** — `switch-profile.sh` bulk-extracts both profile JSON blobs in two `jq | @tsv` calls instead of 14+ individual reads of the same static blobs
- **Single awk for gitignore drift** — `compute-drift.sh` normalises `.gitignore` and diffs against expected entries in one awk pass (vs read-loop + per-entry `grep -Fxq`)

### Fixed

- **Unused `hook_name` variable** — removed dead assignment in `install-hooks.sh` husky publish loop (shellcheck SC2034)
- **macOS `md5sum` portability** — `session-check.sh` cache key generation falls back to `md5 -q` or `cksum` when `md5sum` is unavailable
- **CLAUDE.md hint field shifting** — `detect_claudemd_hints` awk output now tab-delimited so empty middle fields don't collapse during `read`
- **Parallel doc subsystem path safety** — `compute-drift.sh` dispatches subsystems via arrays instead of word-split strings, fixing breakage with spaces in paths
- **Session cache key includes branch refs** — `session-check.sh` cache keyed on HEAD SHA + `refs/heads` digest so branch creates/deletes/merges within TTL invalidate correctly
- **`--stack` file missing is now a hard error** — `suggest-profile.sh` dies instead of silently falling back to re-running `detect-stack.sh`
- **Pre-filter malformed profiles in `suggest-profile`** — one corrupt JSON in `~/.claude/nyann/profiles/` no longer aborts the entire scoring batch; bad files are skipped with a warning
- **Atomic session-check cache write** — write goes to `${cache_file}.tmp.$$` then `mv` so concurrent skill invocations cannot observe a partial cache; reads pull all sections in one awk pass with a numeric ts validation guard
- **`IFS=$'\t'` on `@tsv` reads in `suggest-profile` + `doctor`** — same tab-collapse bug class as the `detect_claudemd_hints` fix, prevented in two more callers consuming jq `@tsv` output
- **Cleanup trap covers earlier tmpfiles in `compute-drift`** — single trap installed up-front with `${var:+}` guards covers both `norm_file` (now removed) and `_drift_tmpdir` so SIGINT can't leak either
- **`path_under_target` accepts target `/`** — root special-cased before the literal `//*` pattern test that would otherwise reject all paths
- **User profiles shadow starter profiles in `suggest-profile`** — same-name dedupe at file-collection time (mirroring `load-profile.sh` resolution) instead of confidence-tied jq sort
- **Disable session-check cache when digest unavailable** — `session-check.sh` sets `cache_ttl=0` and clears `cache_file` when both `md5sum`/`md5`/`cksum` are missing, eliminating cross-repo pollution from the old shared `stale-branches-fallback` filename
- **Bootstrap skill capture step** — step 1 now redirects `detect-stack.sh` to `${TMPDIR:-/tmp}/nyann-stack.json` so step 2's `--stack` flag has a real path to consume
- **Per-profile sentinel keyed on `(plugin_version, sha256)`** — `load-profile.sh` writes one sentinel per starter profile under `profiles/_validated/`; survives plugin downgrades and detects mid-version starter edits

## [1.3.0] - 2026-05-01

### Added

- **Semver version recommendation** — `recommend-version.sh` walks Conventional Commits since the last tag and suggests the next semver bump (major/minor/patch); pre-1.0 semantics supported; `BREAKING CHANGE` / `BREAKING-CHANGE` footers parsed from commit bodies
- **CI governance gate** — `doctor-ci.sh` runs drift-aware PR health checks inside GitHub Actions; configurable threshold, severity, ignore list; optional inline PR comment with score breakdown
- **Health trending** — `health-trend.sh` reads `memory/health.json` history and computes sparkline, trajectory (improving/stable/declining), and per-category deltas
- **Profile suggestion** — `suggest-profile.sh` scores all starter profiles against a detected stack descriptor; returns ranked primary and secondary suggestions with confidence scores
- **Profile diff** — `diff-profile.sh` produces a structured 10-section diff between any two profiles (hooks, branching, conventions, extras, documentation, etc.)
- **`/nyann:diff-profile` skill and command** — compare two profiles side-by-side from a slash command or natural language
- 3 new JSON schemas: `health-trend.schema.json`, `profile-suggestion.schema.json`, `profile-diff.schema.json`
- Governance CI workflow template (`templates/ci/governance-check.yml`)

### Changed

- **Bootstrap profile selection** — replaced static profile lookup with `suggest-profile.sh` scoring; multi-stack repos surface secondary suggestions
- **Doctor skill** — added §5 health trend surface when history is available
- Schema count increased from 40 to 43
- Skill and command count increased from 30 to 31

### Fixed

- **`recommend-version.sh`** — no-commits bump is now `"none"` (was incorrectly `"patch"`); `BREAKING CHANGE` footers in commit bodies are now detected
- **`doctor-ci.sh`** — fixed dead-code warn status logic; added explicit flag tracking for threshold/severity CLI overrides; profile name regex validation; ignore entries trimmed in JSON output; symlink check on `--comment-file`
- **`health-trend.sh`** — `--last` now validates as positive integer (rejects 0, negative, non-numeric)
- **`diff-profile.sh`** — added `commit_scopes` to conventions diff; fixed unbound variable crash with empty temp file array; added cleanup trap
- **`gen-ci.sh`** — branch names validated via jq regex filter; wildcard workspace `*` filtered from paths stanza; fixed `IFS` join that produced `main,develop` instead of `main, develop`
- **`inspect-profile.sh`** — added 6 missing hook blurbs for v1.2.0 profiles: `dotnet-format`, `checkstyle`, `dart-analyze`, `dart-format`, `pint`, `rubocop`
- **`compute-health-score.sh`** — `claude_md` now included in `max_deductions` output (required by governance schema)
- **Governance CI template** — stderr no longer pollutes health-score JSON; profile name regex validation; pinned nyann git clone to tagged version

## [1.2.1] - 2026-05-01

### Fixed

- **Missing hook blurbs for v1.2.0 profiles** — `hook_blurb()` in `inspect-profile.sh` now maps all 6 hook IDs added in v1.2.0 (`checkstyle`, `dotnet-format`, `pint`, `dart-format`, `dart-analyze`, `rubocop`), fixing CI failure in test "every bundled profile hook id has a mapped blurb"

## [1.2.0] - 2026-04-30

### Added

- **Java stack detection and profile** — `detect_java()` recognizes `pom.xml` and Gradle projects with `.java` files; framework inference for Spring Boot, Quarkus, Micronaut; `java-spring-boot` starter profile with Checkstyle hooks
- **C# / .NET stack detection and profile** — `detect_dotnet()` recognizes `.csproj`, `.sln`, `.fsproj`; framework inference for ASP.NET, Blazor, MAUI; `dotnet-api` starter profile with dotnet format hooks
- **PHP stack detection and profile** — `detect_php()` recognizes `composer.json`; framework inference for Laravel, Symfony; `php-laravel` starter profile with Pint hooks
- **Dart / Flutter stack detection and profile** — `detect_dart()` recognizes `pubspec.yaml`; Flutter SDK detection; `flutter-app` starter profile with dart format and dart analyze hooks
- **Ruby stack detection and profile** — `detect_ruby()` recognizes `Gemfile`; framework inference for Rails, Sinatra; `ruby-rails` starter profile with RuboCop hooks
- **Extension-count fallback** expanded to detect `.java`, `.cs`, `.php`, `.dart`, `.rb` files
- **CLAUDE.md hint parser** expanded to recognize Java, C#/.NET, PHP, Dart/Flutter, Ruby references

### Changed

- Starter profile count increased from 13 to 18
- StackDescriptor and Profile schemas updated with new language, framework, and package manager enum values

## [1.1.2] - 2026-04-28

### Fixed

- **Post-bootstrap skill invocation** — bootstrap nudges now show exact flag syntax for `learn-profile.sh` (`--name <slug>`, not positional) preventing "unknown argument" errors
- **Doctor profile resolution** — doctor skill now explicitly documents that `--profile` takes a bare name (e.g. `python-cli`), not a filesystem path, preventing "invalid profile name" errors

## [1.1.1] - 2026-04-27

### Fixed

- **Plugin hook path resolution** — hooks now use `${CLAUDE_PLUGIN_ROOT}` so `block-main` and `track-claudemd-usage` work from any working directory, not just the plugin root
- **AskUserQuestion reliability** — all 8 picker skills now use exact JSON tool-call structures with `MUST call` directives; Claude no longer falls back to plain-text questions
- **Setup UX overhaul** — streamlined from 5 phases to 4 steps with a quick-setup fast path (1 picker for the happy path), categorized prereqs tables, and explicit flag value mapping to prevent mismatches like `conventional` vs `conventional-commits`
- **Plugin discovery** — all 30 command files include a plugin root preamble so Claude resolves script paths immediately without searching via `which`/`npm list`/`brew list`

## [1.1.0] - 2026-04-27

### Added

- **Interactive selection menus** — 8 skills now use `AskUserQuestion` pickers instead of free-text prompts: setup (branching, commits, GitHub CLI, docs, team sync), commit (confirm/edit/abort), new-branch (purpose), route-docs (routing), undo (strategy), ship (mode), sync (strategy), record-decision (status)
- **Inline drift checks** — drift detection runs at point-of-use (commit, pr, ship, release) as a non-blocking nudge; team-staleness checks run at bootstrap and migrate-profile
- **README banner** — bamboo scaffolding logo banner

### Changed

- **Friendly error handling** — scripts that emit structured JSON (setup, commit, sync, ship) now exit 0 and convey state via JSON status/outcome fields instead of non-zero exit codes that caused Claude Code to display raw JSON as errors
- **Monitors removed from session start** — `monitors.json` emptied; checks moved to point-of-use in skill preambles
- **CI triggers** — removed `dev` from `pull_request` trigger to prevent duplicate CI runs

### Fixed

- **Nightly eval regression** — eval runner now passes `--plan-sha256` to `bootstrap.sh` (closes #6)
- **Flaky doctor timing test** — increased threshold from 5s to 15s for CI runner variability
- **Ubuntu CI** — resolved bats test failures on bash 5.x, suppressed shellcheck false positives

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

[1.3.0]: https://github.com/thettwe/nyann/releases/tag/v1.3.0
[1.2.1]: https://github.com/thettwe/nyann/releases/tag/v1.2.1
[1.2.0]: https://github.com/thettwe/nyann/releases/tag/v1.2.0
[1.1.2]: https://github.com/thettwe/nyann/releases/tag/v1.1.2
[1.1.1]: https://github.com/thettwe/nyann/releases/tag/v1.1.1
[1.1.0]: https://github.com/thettwe/nyann/releases/tag/v1.1.0
[1.0.0]: https://github.com/thettwe/nyann/releases/tag/v1.0.0
