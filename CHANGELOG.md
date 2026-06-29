## [1.13.0] — 2026-06-29

### Theme: Infrastructure as Code

nyann becomes first-class for IaC repos — detecting and governing AWS CDK, Pulumi, Kubernetes, Helm, and Ansible alongside Terraform/OpenTofu — and completes the proactive-awareness arc started in v1.12.0: the CI sentinel now runs as a supervised background daemon, delivers to external channels, and aggregates across many repos, joined by an opt-in coverage-delta PR guard.

### Features

- **IaC detection + 5 first-class starter profiles (I2–I6)** — `bin/detect-stack/detect-iac.sh` now recognizes AWS CDK (`cdk.json`), Pulumi (`Pulumi.yaml`), Kubernetes / Kustomize (`kustomization.yaml`, bare manifests), Helm (`Chart.yaml`), and Ansible (playbooks / `ansible.cfg`) on top of Terraform/OpenTofu. Five new starter profiles — `aws-cdk-app`, `pulumi-app`, `kubernetes-app`, `helm-chart`, `ansible-playbook` — each ship detect signatures, per-tool hook templates, CI generation, and `infra`-archetype doc scaffolding, with every tool soft-skipping when its CLI isn't installed.
- **Deep IaC workspace discovery (I7)** — `bin/detect-stack/discover-iac-units.sh` walks an IaC monorepo into a unit **dependency graph** (`depends_on` edges — paths for Terraform, names for Helm/Ansible), made cycle-safe and name-collision-safe, emitting the shape that drift detection and per-unit release consume.
- **IaC drift detection (I8)** — new detectors for unpinned refs (provider / module / image / chart versions), missing lockfiles, secrets-in-vars, and version-lag against upstream, wired into `doctor` (new IaC DRIFT section) and the pre-action guards so a risky change is flagged before a plan/apply runs. New `iac-drift-report.schema.json`.
- **Per-unit / per-chart versioning in release (I10)** — `release.sh` versions each IaC unit / Helm chart independently with scoped tags, processed in **topological (dependency) order** so a unit is never tagged before something it depends on.
- **Plan/apply preview workflow + `/nyann:plan` and `/nyann:apply` skills (I9)** — a preview-before-mutate workflow across terraform / opentofu / aws-cdk / pulumi / helm / kubernetes / kustomize / ansible. `/nyann:plan` emits a read-only add/change/destroy summary and **never applies**; `/nyann:apply` is opt-in, previews and confirms first, gates destructive applies behind an explicit `--confirm-destroy`, keeps credentials off argv, and writes an audit `IacApplyRecord`. New `iac-plan` + `iac-apply-record` schemas.
- **Backgrounded CI sentinel daemon (P8)** — `bin/sentinel-daemon.sh` supervises the (previously one-shot) `ci-sentinel.sh` poller as a real background daemon under **launchd** (macOS), a **systemd user unit** (Linux), or **`nohup`**. Single-instance guard, an 8h orphan backstop, and exponential backoff on failure; `doctor` surfaces running and stale daemons. Unit templates ship under `templates/launchd/` and `templates/systemd/`.
- **External notification delivery (P9)** — `bin/notify-deliver.sh` plus Slack / Discord / generic-webhook / email channels (`bin/notify-channels/`) deliver sentinel events to real destinations. Wired at the **producer** (`ci-sentinel.sh`) so the daemon, one-shot `/nyann:watch`, and the aggregate all deliver. Secrets are referenced by env-var **NAME** in preferences (never the value), resolved at send time with `printenv`, and kept off the process argv. New `notification-delivery-config.schema.json`; `preferences` gains `notifications.delivery` (schemaVersion 3).
- **Multi-repo sentinel aggregation (P10)** — `bin/sentinel-aggregate.sh` watches a list of repos on a globally rate-limit-aware schedule; `read-notifications.sh --all` renders a repo-tagged merged view across every queue; and `sentinel-daemon.sh --aggregate` runs the aggregator itself as a supervised background daemon (with its own launchd/systemd units). New `watch-list.schema.json`.
- **Coverage-delta PR guard (P11)** — `bin/guards/coverage-delta.sh` (with js / python / go / rust parsers under `bin/coverage-tools/`) is an **opt-in, advisory** guard that reuses an existing CI coverage artifact, compares it against a stored baseline, and warns when coverage drops past a threshold. It never runs a test suite and never blocks the PR. New `coverage-baseline.schema.json`.

### Schema additions

- New: `iac-drift-report`, `iac-plan`, `iac-apply-record`, `notification-delivery-config`, `watch-list`, `coverage-baseline`.
- `sentinel-state.schema.json` — adds the `daemon` liveness block (pid / started_at / supervisor).
- `stack-descriptor.schema.json` — adds the `iac` block; `primary_language` gains `hcl` / `yaml`, `archetype` gains `infra`.
- `profiles/_schema.json` — `framework` enum gains the IaC tools (`terraform`, `opentofu`, `aws-cdk`, `pulumi`, `kubernetes`, `kustomize`, `helm`, `ansible`); adds `guards.coverage_delta_threshold`.
- `preferences.schema.json` — adds `notifications.delivery`; bumps to schemaVersion 3.

### Stats

- Skills: 37 → 39 (added `iac-plan`, `iac-apply` — slash commands `/nyann:plan`, `/nyann:apply`)
- Commands: 37 → 39
- Starter profiles: 27 → 32 (added `aws-cdk-app`, `pulumi-app`, `kubernetes-app`, `helm-chart`, `ansible-playbook`)
- Schemas: 63 → 69 (the 6 new schemas above)
- Background-daemon tooling under `templates/launchd/` + `templates/systemd/` (4 unit files — sentinel + aggregate, launchd + systemd)
- Test count: 1583 → 2038 (v1.12.1 grew the suite 1449 → 1583 without a recorded stat)

[1.13.0]: https://github.com/thettwe/nyann/releases/tag/v1.13.0
## [1.12.1] — 2026-06-06

### Fixes

- pre-release hardening — correctness, security, contracts, docs (#29) (00f379d)

[1.12.1]: https://github.com/thettwe/nyann/releases/tag/v1.12.1
## [1.12.0] — 2026-05-31

### Theme: Proactive Awareness

nyann shifts from purely reactive (nothing fires unless a skill is triggered) to proactively surfacing drift, validating preconditions, and watching CI state — quiet unless something actually changed.

### Features

- **Mandatory setup gate + interactive settings menu (S0)** — every skill now requires `~/.claude/nyann/preferences.json`. `_lib.sh::nyann::require_setup` returns rc 2 with a clear hint when it's missing; in CI / `NYANN_NONINTERACTIVE=true` mode it synthesizes a defaults-only file automatically. New `bin/settings.sh` + `/nyann:settings` skill render and update individual preferences without rerunning the full wizard (`settings.sh --set <key> <value>`). Preferences schema bumps to v2 with `git_identity`, `session_triage`, `guard_default_severity`, and `notifications.{sentinel, staleness_alerts}` fields. Incremental upgrade path preserves existing values when adding new ones.
- **Session-start triage (P1)** — `bin/session-triage.sh` is a quiet UserPromptSubmit-hook wrapper that runs `session-check.sh --flow=session-start` with a 2s hard cap and a fingerprint-based dedup cache under `~/.claude/nyann/cache/<repo-hash>.session-check`. Repeat sessions with the same drift state are silent; new drift surfaces a single notification line. **Registered in the plugin's `hooks/hooks.json` as a UserPromptSubmit hook** — fires automatically on every prompt; opt out via `preferences.session_triage = false`.
- **Pre-action guards (P2)** — `bin/pre-action-guard.sh` orchestrates per-flow checks (commit/pr/release/ship) before the mutating action runs. Built-in guards under `bin/guards/`: `staged-files-exist`, `merge-conflict-markers`, `branch-pushed`, `wip-commits`, `clean-tree`. Profiles can override the active set via `guards.<flow> = [{name, severity}]` and promote `advisory → confirm/critical`. `--skip-guards` always works as an override. **Wired into the `commit`, `pr`, `release`, and `ship` skills** — exit-code-driven (0/3/4) so AskUserQuestion confirms appear on critical/confirm guard failure. New `guard-result.schema.json`.
- **Documentation staleness detector (P4)** — `bin/docs-staleness.sh` flags docs whose correlated sources have churned (≥5 commits) since the doc was last touched, or whose doc-age exceeds 30 days while correlated sources have changed at least once. Thresholds configurable via `documentation.staleness_threshold_commits` / `.staleness_threshold_days`. **Probed by `bin/doctor.sh`**; surfaced as a DOC STALENESS section. New `docs-staleness.schema.json`.
- **Proactive commit hygiene (P5)** — `bin/commit-hygiene.sh` runs three checks on the staged diff before the commit message is generated: (1) scope suggestion from staged paths, (2) incomplete-staging detection (source↔test pairings, package.json↔lockfile drift), (3) debug-artifact scan with `console.log|debugger|print(|TODO|FIXME|XXX` defaults (profile-overridable via `conventions.commit_hygiene_patterns[]`). Dead-code findings (P6) are folded in under `.dead_code`. **Wired into the `commit` skill** at step 1.5 alongside the pre-action guard; the suggested scope pre-fills the CC scope in step 3. New `commit-hygiene.schema.json`.
- **Dead-code / unused-import detection (P6)** — `bin/dead-code-scan.sh` scans the staged diff with per-stack rules in `bin/dead-code-rules/{js,python,go,rust}.sh`. High-confidence findings only by default (single-file imports clearly not referenced elsewhere in the same file). Opt out via `conventions.dead_code_scan = false`. Folded into commit-hygiene above. New `dead-code-scan.schema.json`.
- **Public-doc governance (P7)** — `bin/docs-drift-scan.sh` orchestrates four detectors under `bin/docs-drift/`: version-refs (semver older than latest git tag — skips CHANGELOG.md), file-refs (broken markdown link targets), script-refs (`npm run X` / `make X` referenced but missing from package.json / Makefile), count-claims (opt-in numeric claims like "1318 tests" cross-referenced against a filesystem-glob source). Respects `<!-- drift-ignore -->` markers per line. Profile block: `documentation.drift_check.{enabled, scanned_files, version_refs, file_refs, script_refs, count_claims}`. **Probed by `bin/doctor.sh`**; surfaced as a PUBLIC-DOC DRIFT section. Critical/high findings escalate doctor's exit code (mirrors gh-protection). New `docs-drift-report.schema.json`.
- **README SVG toolkit (C3)** — `bin/gen-readme-badges.sh` emits a marker-bracketed shields.io badge block (license, ci, release, tests, health, package-manager — each independently togglable). `bin/gen-readme-stack-icons.sh` emits a `skillicons.dev` block using `templates/stack-icon-map.json` to translate detected stack signals into slugs. `--apply` writes the block into README.md; reruns are idempotent. Master + per-badge flags under `documentation.readme_badges` / `documentation.readme_stack_icons`. New `readme-badge-block.schema.json`.
- **CI sentinel + notifications (P3)** — `bin/ci-sentinel.sh --repo <owner/repo> [--pr <N>]` polls open PRs via `gh` and emits state-transition notifications (`checks: pending → failure/success`, `review: → changes-requested/approved`, `merged`). `bin/read-notifications.sh` reads + clears the per-repo notification queue (`~/.claude/nyann/notifications/<repo-hash>.jsonl`). `--stop` kills the per-repo pid file. New `/nyann:watch` skill wraps the sentinel for ad-hoc starts. New `sentinel-state.schema.json` + `notification.schema.json`.
- **IaC minimal (I1)** — new `infra` archetype + `hcl` primary language in `profiles/_schema.json`. `bin/detect-stack/detect-iac.sh` recognizes `*.tf`, `cdk.json`, `Pulumi.yaml`, `Chart.yaml`, `kustomization.yaml`. New `profiles/terraform-monorepo.json` starter wires `terraform-fmt`, `terraform-validate`, `tflint`, `tfsec`, `terraform-docs` (each soft-skips when the underlying tool isn't installed). Hook templates under `templates/hooks/iac/`; new `templates/pre-commit-configs/iac.yaml` config + `install-hooks.sh --iac` phase materializes them into `.nyann/hooks/iac/` and writes `.pre-commit-config.yaml`. `bootstrap.sh` auto-selects the IaC phase when the detected language is `hcl` OR the profile's archetype is `infra` / framework is `terraform`. Archetype scaffold map adds `infra → architecture/runbook/deployment/adrs/glossary`. Full IaC coverage (CDK, Pulumi, K8s as first-class profiles) deferred to v1.13.0.

### Schema additions

- `preferences.schema.json` — bumps to `v2` with `git_identity`, `session_triage`, `guard_default_severity`, `notifications`.
- `profiles/_schema.json` — adds `guards`, `documentation.staleness_threshold_commits`, `documentation.staleness_threshold_days`, `documentation.drift_check`, `documentation.readme_badges`, `documentation.readme_stack_icons`, archetype `infra`, primary_language `hcl`.
- New: `guard-result`, `dead-code-scan`, `commit-hygiene`, `docs-staleness`, `docs-drift-report`, `readme-badge-block`, `sentinel-state`, `notification`, `session-triage`.

### Stats

- Skills: 35 → 37 (added `settings`, `watch`)
- Commands: 35 → 37
- Starter profiles: 26 → 27 (added `terraform-monorepo`)
- Schemas: 53 → 62
- New test files: 12 (test-setup-gate, test-settings, test-session-triage, test-pre-action-guards, test-dead-code-scan, test-commit-hygiene, test-docs-staleness, test-docs-drift, test-gen-readme-badges, test-gen-readme-stack-icons, test-detect-iac, test-ci-sentinel)
- Test count: 1431 → 1449 (regression coverage for the IaC install phase, deep monorepo Terraform layout detection, gen-readme orphaned-marker refusal, terraform-docs partial-staging restriction, ci-sentinel --pr integer validation, TypeScript type-only imports, Python imports with trailing comments; plus pre-action guard demotion-refusal, pre-release semver comparison, Helm corroboration, and docs-drift false-positive suppression for parenthesised prose / fenced code / historical version refs)

### Deferred to v1.13.0

- Full IaC coverage (`aws-cdk-app`, `pulumi-app`, `kubernetes-app`, `helm-chart`, `ansible-playbook` profiles + per-module versioning + plan/apply workflow).
- External notification delivery (Slack/Discord/email webhooks for P3 sentinel).
- Multi-repo sentinel aggregation.
- Coverage-delta guard for the PR flow (stack-aware integration with jest/coverage.py/go test/tarpaulin).
- True backgrounded sentinel daemon (the current `bin/ci-sentinel.sh` is one-shot per call; daemonize via the caller's `nohup` or launchd wrapper).

## [1.11.0] — 2026-05-28

### Features

- **Profile composition (`extends`)** — profiles can inherit from a parent via `"extends": "node-api"` with deep merge semantics. Arrays replace; objects merge recursively; max chain depth 3; circular detection. Validates merged result against schema. New `bin/merge-profiles.sh` helper, `_meta.extends_chain[]` surfaces resolution path. (fb200b8)
- **Monorepo workspace release** — `release.sh` gains `--workspace <path>` and `--all-workspaces` for per-workspace versioning, scoped tags (`core@2.1.0`), and scoped CHANGELOG sections. `--batch-commit` mode groups all workspace releases into a single commit (with tags pointing to that commit). New scripts under `bin/release/`: `release-workspace.sh`, `detect-workspace-changes.sh`. (c735c25)
- **PR risk score in `/nyann:ship`** — composite score from churn (40%), test gap (40%), and health delta (20%). Surfaces a `low|medium|high` level with actionable recommendations before the PR is created. New `bin/pr-risk-score.sh` + schema. (0f4c874)
- **CODEOWNERS generation extended to single-repo profiles** — generation no longer requires a workspaces array. New `bin/derive-codeowners.sh` suggests owners from git history (commit authors over a configurable threshold) when no explicit `code_owners` are declared. (3580f91)
- **Team profile pinning (SHA + tag)** — `nyann:add-team-source` accepts `pin_strategy: sha|tag|branch`. Pinned sources require explicit `--accept-update` to advance; auto-sync respects pins. New `--check-updates` mode reports changelog between pinned and HEAD. (b94e151)

### Refactors

- **Orchestrator extraction** — three monoliths split into sourced modules under per-feature directories:
  - `bin/release.sh` (1,059 lines) → `bin/release/{bump-manifests,ci-gate,collect-commits,detect-workspace-changes,github-release,push-release,release-workspace,render-changelog}.sh` (a3eeaa2)
  - `bin/gh-integration.sh` (885 lines) → `bin/gh-integration/{apply-protection,audit-branch-protection,audit-codeowners,audit-repo-settings,audit-security,audit-signing,audit-tag-protection,_helpers}.sh` (7fe5ea6)
  - `bin/detect-stack.sh` (1,497 lines) → `bin/detect-stack/{detect-archetype,detect-go-rust,detect-hints,detect-jsts,detect-mobile-systems,detect-python,detect-v110-stacks,discover-workspaces,_detect-common}.sh` (16f173e)

### Fixes

- **Security hardening** — 13 fixes from multi-agent adversarial review:
  - `$target` variable was clobbered by sourced `audit-tag-protection.sh` (renamed to `rs_target`), causing wrong audit output when tag rulesets existed (97a7fad)
  - `script` bump format now requires explicit `--allow-scripts` to execute (prevents arbitrary command execution from compromised profiles) (97a7fad)
  - Code-owner downgrade check no longer noops when both remote and profile want code-owner reviews (97a7fad)
  - Workspace tags now created **after** batch commit so they point to the commit containing changelogs (97a7fad)
  - Empty `ws_result` from failed workspace release no longer crashes `jq` (97a7fad)
  - `git://` protocol rejected from `nyann::valid_git_url` (MITM risk on team profile sync) (97a7fad)
  - `git add -A` in batch workspace release replaced with targeted `git add` of CHANGELOG files only (97a7fad)
  - Workspace release path now propagates non-zero exit when any workspace fails (97a7fad)
- **Tests** — fix git identity and default branch for CI portability (`git init -b main` + `git config user.email/name` in temp repos) (b3679ad, 92187e1)
- **Lint** — add shellcheck SC2034 directives for variables consumed by sourced modules (31c310f)
- **Additional security hardening** — follow-up adversarial review caught further input-validation and locking edge cases (bcbac3e)
- **`detect-workspace-changes.sh`** — fix SC2106 (continue inside subshell) (6024847)

### Schema additions

- `profiles/_schema.json` — `extends` field; namespaced `team/name` extends format supported
- `schemas/release-result.schema.json` — new `WorkspaceRelease` variant for monorepo output
- `schemas/workspace-release-result.schema.json` — `oneOf` with success and error variants
- `schemas/pr-risk-score.schema.json` — new
- `schemas/team-profile-changelog.schema.json` — new

### Stats

- Files changed: 47 · Lines: +4801 −2626
- New starter profiles: 0 (focus was on infrastructure)
- New schemas: 5
- New test files: 7 (~180 new cases)

## [1.10.0] — 2026-05-28

### Added

- **8 new starter profiles** — `deno-app`, `bun-app`, `sveltekit-app`, `astro-site`, `nuxt-app`, `phoenix-app`, `nestjs-service`, `cpp-cmake`. Each ships with detect-stack signatures, hook templates, CI generation support, and archetype mapping. Brings the starter profile count from 20 to 28.
- **`bin/gen-dependency-updater.sh` + `/nyann:gen-dependency-updater` skill** — profile-aware Dependabot or Renovate config generation. Opt-in via `extras.dependency_updater: "dependabot" | "renovate"` on the active profile. Templates cover all supported ecosystems (npm, pip, Go modules, Cargo, Maven, Gradle, Composer, Bundler, Pub, NuGet, Mix). Defaults: weekly schedule Monday 04:00 UTC, 5 open-PR limit, minor+patch grouped. Idempotent — diffs against existing config and refuses to overwrite without `--force-overwrite`.
- **`bin/gen-devcontainer.sh` + `/nyann:gen-devcontainer` skill** — profile-aware `.devcontainer/devcontainer.json` generation for Codespaces and VS Code Remote Containers. Templates per primary language (Node, Python, Go, Rust, Dart, Java, .NET, PHP, Ruby, Swift, Elixir, C++). Includes pinned dev-container features (GitHub CLI, git-lfs, common-utils). Opt-in via `extras.devcontainer: true`. Codespaces-aware: emits `hostRequirements` for resource sizing.
- **`bin/explain-diff.sh` + `/nyann:explain-diff` skill** — translates a DriftReport JSON into plain-English markdown narrative without requiring LLM access. Pure template substitution with severity-to-tone mapping (critical → "Action required", high → "Worth fixing", medium → "Drifted", low → "Minor"). Includes actionable remediation suggestions per drift category.
- **`doctor --explain` flag** — pipes the drift report through `explain-diff.sh` and writes both the JSON and the narrative. Gives operators a paste-ready summary for PRs and team channels.
- **`bin/detect-stack.sh` gains 8 new detector functions** — `detect_deno()`, `detect_bun_native()`, `detect_sveltekit()`, `detect_astro()`, `detect_nuxt()`, `detect_phoenix()`, `detect_nestjs()`, `detect_cpp_cmake()`. Each returns the standard `StackDescriptor` JSON shape (no schema change). Archetype ladder extended to map all new frameworks.
- **`bin/_lib.sh` new validators** — `nyann::valid_dependency_updater`, `nyann::valid_devcontainer_stack` for input validation in the new generators.

### Changed

- **`profiles/_schema.json`** — gains `extras.dependency_updater` (string or bool) and `extras.devcontainer` (bool). Both optional, backward-compatible.
- **`bin/inspect-profile.sh`** — surfaces the new `dependency_updater` and `devcontainer` extras in profile summaries.
- **`bin/scaffold-docs.sh`** — minor refactor to doc-archetype mapping for the new stacks.
- **`bin/find-orphans.sh`** — respects `templates/orphan-exclusions.txt` so new template directories don't trigger false positives.
- **`docs/RELEASING.md`** — corrects the `@nyann` → `@nyann-plugins` marketplace token.

### Schemas added

- `dependency-updater-config.schema.json` — input shape for gen-dependency-updater.sh.
- `devcontainer-config.schema.json` — input shape for gen-devcontainer.sh.
- `drift-narrative.schema.json` — output shape of explain-diff.sh (header, sections, action items).
- `stack-descriptor.schema.json` extended with new framework enum values.

### CI + tests

- **6 new bats test files** — `test-detect-v110-stacks.bats` (300 lines, 8-stack detection coverage), `test-gen-dependency-updater.bats` (265 lines), `test-gen-devcontainer.bats` (254 lines), `test-explain-diff.bats` (217 lines), `test-doctor-explain-flag.bats` (109 lines), `test-schema-validation.bats` (95 lines for the 3 new schemas).
- **`test-find-orphans.bats`** — 38 lines covering exclusion-list support.
- **`test-public-surface-counts.bats`** — updated: profile count 20 → 28, schema count 49 → 52, skill count 34 → 37.
- **`community-marketplace-reminder.yml` removed** (PR #23) — replaced by the `--prepare-submission` workflow documented in RELEASING.md.
- Suite: 1147 → 1250 tests. Schemas: 49 → 52. Starter profiles: 20 → 28.

### Deferred

- **Orchestrator extraction** — `release.sh` (1,059 lines), `gh-integration.sh` (885 lines), `detect-stack.sh` (1,496 lines) remain monolithic. Deferred again from v1.9.0; scheduled for v1.11.0 as feature X1 (spec: `docs/roadmap/v1.11.0-spec.md`).
- **Profile composition / `extends`** — deferred to v1.11.0 as feature A1 (spec: `docs/roadmap/v1.11.0-spec.md`).

## [1.9.0] — 2026-05-16

### Added

- **Workspace-aware profiles (monorepo support)** — `profiles/_schema.json` gains `workspaces[].profile`, letting a single root profile assign different child profiles to each workspace path. Bootstrap, retrofit, docs, hooks, CI, and CLAUDE.md generation now honour per-workspace assignments instead of forcing one profile across a polyglot repo.
- **`bin/resolve-workspace-configs.sh`** — merges detected workspace paths (from `detect-stack.sh`) with profile overrides (per-workspace `profile`, `ci`, `documentation`, `extras`) and emits a normalised `WorkspaceConfigs` JSON array consumed by every downstream subsystem. Covered by `tests/bats/test-resolve-workspace-configs.bats` (8 new cases).
- **`schemas/workspace-configs.schema.json`** — new contract locking the per-workspace config shape, including optional `profile`, `ci`, and `documentation` overrides.
- **Per-workspace docs scaffolding** — `bin/scaffold-docs.sh --workspace-configs` materialises workspace-local `docs/` directories for workspaces whose assigned profile declares `documentation.scaffold_types`. Wired into `bin/bootstrap.sh` after step 4c (workspace resolution) so the scaffolder sees workspace assignments before writing.
- **Per-workspace CI matrix** — `bin/gen-ci.sh` emits a per-workspace lint/typecheck/test matrix when the resolved configs declare CI overrides. YAML-safe key sanitization keeps matrix keys path-traversal-free.
- **Per-workspace gitignore** — bootstrap step 5b writes workspace-local `.gitignore` files from the workspace language template (`jsts`, `python`, `dart`, etc.) when `extras.gitignore=true` on the workspace config.
- **Workspace guidance in generated CLAUDE.md** — `bin/gen-claudemd.sh` appends a per-workspace section listing each workspace, its assigned profile, and a one-line responsibility hint, so agents reading CLAUDE.md know where work belongs.
- **`workspace_suggestions[]` in profile-suggestion output** — `bin/suggest-profile.sh` extends `ProfileSuggestion` with per-workspace profile recommendations for monorepos, surfacing the best-matching profile per workspace stack. Schema: `schemas/profile-suggestion.schema.json` (optional field, backward-compat).
- **`bin/detect-doc-conformance.sh`** — new read-only scanner that compares docs in a repo against canonical archetype paths and proposes reorganisation moves. Emits a JSON array of `{source, target, category, confidence}` entries consumed by `compute-drift.sh` and `reorganize-docs.sh`. 284 LOC, 0 mutations.
- **`bin/reorganize-docs.sh`** — preview-by-default move executor. Reads an approved subset of conformance proposals and executes via `git mv` (in-repo) or `mv`. Preview-before-mutate: without `--apply`, the script previews planned moves and exits without touching the filesystem. Hardened against path traversal, symlink-mediated escape, target overwrites, and `mkdir`/`cat` failures.
- **Doc misplacement in drift reports** — `bin/compute-drift.sh` now invokes `detect-doc-conformance.sh` and surfaces results as a `misplaced[]` array in the `DriftReport`. Both `doctor` (read-only) and `retrofit` (remediation) report it; retrofit offers to invoke reorganize-docs. Conformance script failures are now logged via `nyann::warn` rather than silently swallowed.
- **`bin/detect-stack.sh::detect_doc_hints`** — new doc-archetype hint emitter consumed by conformance detection. Identifies common doc patterns (single README, `docs/` directory, archetype split) so reorganization proposals respect the user's existing layout style.
- **`bin/detect-mcp-docs.sh` multi-source + vault discovery** — settings are now read from multiple sources (`settings_sources[]`) and Obsidian vaults under the project root are auto-detected (`discoverable_vaults[]`). New `--project-path` flag lets callers scope discovery to a workspace subtree rather than `$PWD`.

### Changed

- **`bin/bootstrap.sh` step ordering** — workspace config resolution (step 4c) now runs before doc scaffolding (step 5). The previous order left scaffold-docs unable to see per-workspace documentation settings; its `--workspace-configs` block was effectively unreachable. The renamed step "5b: per-workspace gitignore" reflects the cleaned sequence (4c → 5 → 5b → 5c).
- **`bin/release.sh` rollback failures now warn** rather than silently swallowing — `release.sh` previously routed every rollback path through `|| true`, so a partial-tag-creation or partial-commit failure during rollback was invisible. Failed rollback steps now log `nyann::warn` with the specific subsystem, letting the operator finish the cleanup by hand.
- **`bin/gen-ci.sh` marker matching** tightened from substring to `grep -Fxq` (anchored, full-line) — a workspace named `lint` no longer falsely matches the legacy single-job `lint` marker comment in a hand-edited `ci.yml`.
- **`bin/scaffold-glossary.sh` IFS refactor** — `IFS=','` array splitting replaced inline `tr`/`awk` pipelines for parsing language and term lists, eliminating subtle word-splitting bugs with terms containing whitespace.

### Fixes

- **`bin/reorganize-docs.sh` defaults to preview, not mutate** (audit-flagged hard block) — the initial implementation took `--dry-run` as opt-in and silently `git mv`-ed files by default. That violates nyann's preview-before-mutate non-negotiable. The script now previews unless `--apply` (or `--yes`) is passed; callers in `bootstrap-project` and `retrofit` skills updated to pass `--apply` after user confirmation.
- **`bin/reorganize-docs.sh` mkdir failure is now caught** — an unchecked `mkdir -p "$(dirname "$target_abs")"` could leave a move un-executed while reporting success (errexit aborted the iteration mid-row, never incrementing `fail_count`). Wrapped with explicit failure handling.
- **`bin/reorganize-docs.sh` malformed/unreadable moves files now fail loudly** — `cat` and `jq length` failures used to leave `move_count` as `null` and report "no moves to execute" instead of dying. Both call sites now `nyann::die` with the actual path on failure.
- **`bin/compute-drift.sh` surfaces conformance detection errors** — `detect-doc-conformance.sh` failures used to be swallowed via `|| _conformance_json='[]'` with `2>/dev/null`, masking arg errors, jq failures, and missing scripts. Failures now emit `nyann::warn` before the `[]` fallback (drift report still completes — observability without aborting).
- **`schemas/drift-report.schema.json` and `schemas/profile-suggestion.schema.json` stay backward-compatible** — initial v1.9.0 work added `misplaced` and `workspace_suggestions` to the schemas' `required` arrays, which rejected v1.8.0-compatible fixtures and externally-cached reports. Both fields are now optional (producers still emit them). `documentation.claude_md.additionalProperties` reverted from `false` to `true` so forward-compat fields don't break old consumers.
- **`bin/learn-profile.sh` orphan `--workspace-profiles` flag removed** — the flag was parsed but never invoked by any caller, skill, or command. Dropped to reduce surface area.
- **`bin/detect-stack.sh` dead `local saved_ifs`** — saving/restoring IFS inside a pipe-subshell body had no effect on the parent shell. Removed the dead save/restore pair.
- **`bin/release.sh` script-format bump warning** no longer fires during dry-run preview — the planned command is already surfaced in the bump-plan JSON, so the extra warn just added noise. The warn still fires at apply time as a final security alarm before the script executes.
- **`bin/detect-mcp-docs.sh` settings precedence corrected** (Codex adversarial review #1) — the multi-source merge appended `.claude/settings.local.json` before `.claude/settings.json`, and the merge takes "later sources win", so the checked-in project file silently overrode the user's local override. Order is now global → project `settings.json` → project `settings.local.json`, matching Claude Code's own precedence. A regression test guards against re-inverting.
- **Per-workspace bootstrap writes now pre-enumerated into `plan.writes[]`** (Codex adversarial review #2) — `bin/plan-bootstrap.sh` resolves workspace configs for monorepo stacks and emits per-workspace `.gitignore` + doc-scaffold paths into `plan.writes[]` upfront. The operator sees every workspace file in the preview before confirming, and `bin/bootstrap.sh`'s existing snapshot loop now picks workspace writes up automatically — so `undo-bootstrap` can reverse a monorepo bootstrap cleanly. `_br_category_for` learned to classify nested paths (`packages/*/.gitignore` → `gitignore`, `packages/*/docs/*` → `docs`) so undo's scope filter works.
- **`bin/resolve-workspace-configs.sh` forwards inline `documentation` and `ci` overrides** — the exact-path and wildcard override branches dropped `documentation` and `ci` fields from inline workspace configs (only named-profile workspaces preserved them). Workspace doc scaffolding silently no-op'd as a result. Both fields now flow through all three override branches.
- **`bin/scaffold-docs.sh` renders workspace docs with workspace stack context** (Codex adversarial review #3) — the v1.9.0 workspace-doc loop reused the root repo's `primary_language`/`framework`/`package_manager`/`project_name` template variables, so a Python workspace under a TypeScript root got TS-flavoured architecture/PRD copy. Each workspace iteration now runs inside a subshell that shadows those variables with the workspace's resolved stack metadata. Root-doc rendering is unaffected (subshell scope).
- **`bin/scaffold-docs.sh --allowed-writes` runtime preview-gate** — scaffold-docs.sh's workspace-doc loop now optionally accepts a newline-delimited list of plan-approved write paths. When provided (bootstrap.sh builds it from `plan.writes[]` and passes it in), every workspace doc target is checked against the set before writing; targets absent from the list are skipped with a warn. Defends against planner/executor drift: if `plan-bootstrap.sh` and `resolve-workspace-configs.sh` ever disagree on which scaffolds belong in the plan, the gap is caught at write time instead of materialising files behind the operator's preview. Back-compatible: when `--allowed-writes` is omitted (direct callers), the loop behaves as before.
- **`bin/resolve-workspace-configs.sh` named-profile ci/documentation override merging** — the named-profile branch initialised `resolved_ci`/`resolved_documentation` from the loaded profile, but the wildcard and exact-override layers only merged hooks/extras/owner — ci/documentation overrides on named-profile workspaces were silently dropped, making `{"profile":"react-vite","ci":{"enabled":false}}` impossible. Both override layers now deep-merge ci/documentation against the named-profile base using the same `$base * $override` jq pattern as hooks/extras. Profile schema extended to formally allow `ci` and `documentation` in workspace overrides (with restricted property sets so workspace-specific keys like `lint`/`typecheck`/`test` and `scaffold_types` are validated).
- **`bin/resolve-workspace-configs.sh` routes named profile loading through `bin/load-profile.sh`** — previously `load_named_profile()` concatenated the workspace-supplied profile name into a filesystem path and `cat`'d the result. Bypassed `nyann::valid_profile_name` validation and `validate-profile.sh` schema checks; a crafted workspace `profile: "../../etc/passwd"` would have read arbitrary `.json` files. The function now (a) rejects names that don't match the canonical profile-name regex, and (b) delegates the actual load to `load-profile.sh` so the workspace named-profile path goes through the same validation/migration/source-resolution pipeline as every other profile read.
- **`bin/gen-ci.sh` workspace matrix installs pnpm and Bun toolchains** — the single-stack TypeScript template already invokes `pnpm/action-setup` when needed; the per-workspace matrix workflow regressed and only set up Node, so a pnpm workspace would bootstrap green and immediately ship a CI workflow that failed on first run with "pnpm: command not found". The matrix now emits `pnpm/action-setup@v4` and `oven-sh/setup-bun@v2` steps conditional on a new `matrix.package-manager` field threaded into each include entry.
- **`.github/workflows/community-marketplace-reminder.yml` workflow_dispatch latest-release fallback** — the input description said "Leave blank to use the latest release", but the version resolver only checked `inputs.version` and `github.event.release.tag_name` (the latter is empty on manual dispatch), so a blank manual run aborted with "no version resolved". The resolver now falls back to `gh release list --limit 1 --json tagName` when both upstream sources are empty, matching the documented UX.
- **`bin/detect-mcp-docs.sh` no longer scans `$HOME/Documents` for Obsidian vaults** (user-reported privacy fix) — vault discovery is now strictly scoped to `--project-path`. The previous implementation enumerated `.obsidian` directories under `$HOME/Documents` on every bootstrap run, leaking personal vault paths (e.g. `/Users/<user>/Documents/JournalVault`) into the resulting MCPDocTargets JSON. That JSON flows into skill output, drift reports, and — in monorepo bootstrap flows — boot-record manifests committed to the repo by default. Not a classical exploit (read-only, scope-bounded `find`), but a real scope violation: nyann's documented surface is the project directory, never `$HOME`. The discovery-from-home feature is dropped entirely; vaults outside the project tree need to be wired in via a configured MCP server before nyann knows about them. Regression test in `tests/bats/test-detect-mcp-multi-source.bats` stages a fake `$HOME` with a vault and asserts the bootstrap output never contains it.
- **`bin/boot-record.sh` records the repo basename instead of the absolute target path** (privacy audit follow-up) — `manifest.json` is committed by default under `memory/.nyann/bootstraps/<timestamp>/`, so writing `"target": "/Users/<author>/Works/<repo>"` leaked the original author's username and filesystem layout to anyone who pulled a bootstrap PR. The field is informational (v1.8.0 already stopped comparing it against the runtime target for portability), so storing just `basename($target)` is a strict improvement. Schema description and regression test updated to lock the contract: `manifest.target` must equal the repo basename and must not contain `/`, `$HOME`, or any other path-like content. Surfaced by a follow-up privacy audit after the `$HOME/Documents` fix above.

### Security fixes

- **`bin/gen-ci.sh` validates every matrix scalar to prevent GitHub Actions YAML injection** (security audit — Codex adversarial review, critical) — the existing `_yaml_safe` filter rejected quotes/newlines in `ws_version`/`install`/`lint`/`typecheck`/`test` command strings, but `ws_lang`, `ws_pm`, and the new `*-run` booleans were emitted into the matrix block without validation. A hostile `workspace-configs.json` (from a malicious team-source profile or a compromised PR) could embed newlines/quotes in `.primary_language`, `.package_manager`, or `.ci.{enabled,lint,typecheck,test}` to splice attacker-controlled keys into the generated workflow — the committed `ci-workspaces.yml` would then execute arbitrary commands on the repo's next CI run with the GitHub token in scope. Fix: enforce a strict alphanumeric+`_-` grammar on `ws_lang` and `ws_pm`, and require `*-run` booleans to be exactly `true` or `false`. Hostile values now get `nyann::warn` + skip the workspace. Three new bats regression tests in `test-gen-ci-workspace-matrix.bats` stage each injection vector and assert the generated workflow contains no payload.
- **`bin/scaffold-docs.sh` blocks symlink-mediated escape via intermediate directories** (security audit — Codex adversarial review, critical) — `write_if_missing` rejects leaf symlinks but `mkdir -p` happily follows symlinks at intermediate components. A repo with a pre-placed symlink at `packages/<ws>/docs/decisions` → `/etc/` (or any other directory outside the target) would redirect the workspace doc scaffold's `README.md` / `ADR-template.md` / `.gitkeep` writes outside the target tree. The pre-existing `path_under_target` check on `ws_doc_dir` itself wasn't enough — it ran before the descendant `mkdir -p`. Fix: a new `_ws_safe_mkdir` helper walks every path component from `target_root` to the destination dir, refuses any existing symlinked ancestor, then re-verifies the canonical path stays under target after creation. Every workspace doc write now goes through this helper. Regression test in `test-scaffold-docs-workspace-context.bats` pre-places a symlinked descendant and asserts the script refuses without writing anything to the decoy target.
- **`bin/bootstrap.sh` scaffold-docs gate recognizes workspace-nested paths** — the `docs_in_plan` jq filter previously matched only root-level `docs/` and `memory/` entries. A monorepo whose root profile declared no docs but whose workspace profiles did would surface workspace doc writes in the preview, then skip `scaffold-docs.sh` entirely at execution time — a direct preview-vs-execute mismatch. The filter now also matches `*/docs/...` and `*/memory/...` via `test("(^|/)docs/")`.
- **`bin/bootstrap.sh` workspace `.gitignore` writes gated on `plan.writes[]`** — step 5b used to iterate `ws_configs_file` and run `gitignore-combiner.sh` for every workspace with `extras.gitignore=true`, with no plan-membership check. A buggy or older plan that omitted those paths would leak workspace writes behind the preview. Each workspace `.gitignore` is now skipped + warned unless its exact path appears in `plan.writes[]`.
- **`bin/bootstrap.sh` defensive jq null-coalesce for stack reads** — `pl=$(jq -r '.primary_language' …)` and `sl=$(jq -r '.secondary_languages | join(",")' …)` would abort with "Cannot iterate over null" on a stack.json missing those fields. Both now use `// "unknown"` / `// []` fallbacks.
- **`bin/gen-ci.sh` honors per-workspace `ci.enabled/lint/typecheck/test` flags** — the multi-workspace matrix builder previously parsed `.ci` but only consumed version fields. A workspace with `ci.enabled:false` still got a job; `ci.lint:false` still ran Lint; no `typecheck` step existed at all even when requested. The builder now (a) skips disabled workspaces, (b) emits `lint-run`/`typecheck-run`/`test-run` booleans into each matrix include entry, (c) adds a `Type check` step keyed on `matrix.typecheck-run`, with per-language typecheck commands (tsc/mypy/go vet/cargo check/dart analyze). NB: the boolean defaults use `jq 'if has(X) then .X else true end'` rather than `// true` because the latter coalesces both `null` AND `false` — silently inverting explicit `false` settings was the worst-case bug to leave latent.
- **`bin/gen-ci.sh` no-config sentinels avoid embedded single quotes** — the workspace YAML-safety filter rejects values containing `'`, and the previous `echo 'no lint configured'` sentinel silently caused languages without a profile-declared lint hook (e.g. python without ruff) to be dropped from the matrix entirely. Sentinels are now quote-free.

### CI + tests

- **`.github/workflows/security-scan.yml`** — new SAST workflow running alongside `ci.yml`. Semgrep (`p/bash` + `p/github-actions`) scans `bin/`, `hooks/`, `templates/`, and `.github/` on every push + PR + weekly cron; CodeQL with the `actions` language pack runs on PR + cron only (its actions-language footprint is small enough that per-`dev`-push wouldn't pay for the ~3 min CI cost). `templates/` is deliberately included: those scripts get installed into every nyann-bootstrapped user repo, so a command-injection bug there propagates to every downstream consumer — highest-leverage surface in the whole repo. Findings upload as SARIF to the Security tab; Semgrep is non-blocking during baseline triage. All third-party actions are commit-SHA-pinned (codeql-action `458d36d…` resolved from `v3`); the CodeQL job uses the default query pack (the `actions`-language extended pack is noisier than the compiled-language equivalents — tighten once baseline is clean).
- **`tests/bats/test-fuzz-validators.bats`** — 27-case adversarial sweep over `_lib.sh`'s validators (`path_under_target`, `valid_git_url`, `valid_git_ref`, `valid_profile_name`, `redact_url`). Covers deep `../` chains, `..`-mixed-with-existing-components, sibling-prefix collisions (`repo` vs `repo-evil`), nested symlink chains, self-referential loops, literal `%2e%2e`/spaces/unicode segments, very long paths; `ext::` transport variants (lowercase + uppercase to lock in case-sensitive matching), `--upload-pack=` option injection, `http://` MITM, adjacent non-git schemes (javascript/data/ftp/mailto/vbscript/rsync); credential redaction across every accepted scheme. Pins the existing helpers' behavior so future refactors of `_lib.sh` can't silently widen the attack surface. Brings the total bats suite to 1147.
- **`README.md`** badge / blurb corrected: test count `1044 → 1147` and schema count `47 → 49`.

### Deferred

- **Orchestrator extraction (`release.sh`, `gh-integration.sh`, `detect-stack.sh`)** — these three scripts are 49KB / 41KB / 51KB respectively, past the size where bash review reliably catches edge cases. Splitting each into smaller subsystems (e.g. `detect-stack/{node,python,go,…}.sh`, `release/{plan,write-changelog,commit,tag,rollback}.sh`) would reduce review surface and let `compute-drift.sh`-style focused testing extend to each piece. Not in this release — the refactor is multi-day and touches the most-tested orchestrators in the repo; tracked here so the decision and rationale isn't lost.

### Release-process changes (no runtime impact)

- **`.github/workflows/community-marketplace-reminder.yml`** — new workflow that opens a tracking issue on every published release. The Claude Code community marketplace (`anthropics/claude-plugins-community`) is a read-only mirror that pins each plugin to a specific `source.sha` (~99.8% of all 1,715 listed plugins use SHA pinning); PRs against the mirror are auto-closed, and the SHA only advances when Anthropic's review pipeline approves a fresh "New submission" — there is no "update existing plugin" path in the UI. Without an explicit reminder it's easy to ship a tag, get a green CI run, and never file the next submission — leaving community-install users stuck on the prior version (as happened for v1.2.0 through v1.8.0, all of which the community marketplace never picked up). The action queries the upstream mirror for the currently-pinned SHA, pre-fills a GitHub compare URL between the pin and the new tag, and posts a 5-step checklist linking to the in-app submission portals at `claude.ai/settings/plugins` and `platform.claude.com/plugins/submit`. Idempotent — won't open duplicates if the workflow re-runs for the same version. The issue body also notes that releases can be skipped (one submission supersedes the previous SHA pin), so the maintainer doesn't need to feel obligated to file every patch.
- **`docs/RELEASING.md` post-release verification** now contrasts the two install paths explicitly. `@nyann-plugins` (direct, this repo's `marketplace.json`) updates as soon as the tag pushes; `@claude-community` (curated mirror) requires portal re-submission and a pipeline pass. The same `RELEASING.md` step also corrects the `@nyann` token mismatch — the marketplace name has been `nyann-plugins` since v1.0.0, but the docs said `nyann`.
- **`README.md` install instructions** corrected to `@nyann-plugins` (matches `.claude-plugin/marketplace.json`'s actual `name` field). Adds a note that the community path can lag behind because the upstream mirror is SHA-pinned and synced nightly; users who want immediate updates should use the direct path.

## [1.8.0] — 2026-05-09

### Added

- **`bin/undo-bootstrap.sh`** — closes the long-deferred reversal loop that nyann's preview-before-mutate convention has implied since v1.0. Reads a BootRecord manifest, restores pre-state files, drops branches that were created, and reports anything it couldn't safely undo. Default refusals are conservative: post-bootstrap edits skip without `--force`, branches with new commits past `base_sha` skip without `--allow-non-empty-branches`, HEAD ahead of the seed commit refuses outright without `--allow-rebase`. Mirrors the `--yes`/preview ergonomics of `bin/undo.sh` (commit-undo). Emits `UndoBootstrapResult` JSON on stdout (`schemas/undo-bootstrap-result.schema.json`).
- **`/nyann:undo-bootstrap` skill + slash command** — the user-facing entry point. Trigger phrases include "undo the bootstrap", "revert nyann setup", "uninstall nyann from this repo", "I regret running bootstrap". DISAMBIGUATION clause keeps it cleanly separated from `/nyann:undo` (commit-undo, different scope). When multiple boot records exist (typical: bootstrap + retrofit history), the skill lists them and asks which to undo.
- **`schemas/boot-record.schema.json`** — new contract locking the BootRecord shape. Fields: `schema_version`, `created_at`, `target`, `source` (`bootstrap` | `retrofit`), `profile_name`, `profile_sha256`, `plan_sha256`, `actions[]`. The `actions[]` is a discriminated union over five kinds (`write`, `git-init`, `seed-commit`, `branch`, `default-branch-rename`); write actions optionally carry `pre_state_blob`, `pre_state_sha256`, and `post_state_sha256` so undo can verify pre-state integrity AND detect post-bootstrap user edits.
- **`bin/boot-record.sh`** — pre-mutation snapshot helpers (`nyann::br_init`, `nyann::br_snapshot`, `nyann::br_snapshot_dir`, `nyann::br_action_*`, `nyann::br_finalize`). Sourced by `bootstrap.sh`; the helpers accumulate actions in a tempfile, copy original bytes to `pre-state/<NNNN.bin>`, and emit the final `manifest.json` atomically. Idempotent: a re-snapshot on the same path no-ops; a re-finalize after the inline call no-ops via the EXIT trap.
- **`bin/bootstrap.sh --source bootstrap|retrofit`** — labels the boot record so `/nyann:undo-bootstrap` can tell remediation runs apart from initial setups. Default is `bootstrap`. The retrofit skill now passes `--source retrofit` when re-running bootstrap as remediation.
- **`bin/bootstrap.sh` summary now includes `boot_record`** — absolute path to the just-written manifest.json (or `null` in dry-run). Skill callers surface this so the operator knows where to look.
- **Pre-state coverage** — bootstrap snapshots every path declared in `plan.writes[]` plus the well-known hook side-effect paths that subsystems mutate without enumerating in writes (`.git/hooks/`, `.husky/`, `.pre-commit-config.yaml`, `package.json`, `Cargo.toml`, `lefthook.yml`). The post-state hash is captured at finalize time for every existing file, so undo can distinguish bootstrap's own merge output from a user's later edit.
- **`schemas/undo-bootstrap-result.schema.json`** — locks the UndoBootstrapResult shape. Distinct from `undo-result.schema.json` (commit-undo). Top-level `source` mirrors the BootRecord field; `restored[]`, `deleted[]`, `branches_dropped[]`, `seed_commits_undone[]`, `defaults_renamed_back[]`, and `skipped[]` enumerate the reversals; `scope_applied[]` reports what was processed.
- **2 new bats files** — `test-bootstrap-manifest.bats` (6 tests covering manifest production + schema validation) and `test-undo-bootstrap.bats` (15 tests covering happy paths, refusal modes, scope filtering, source field, and an end-to-end bootstrap+undo against the typescript-library profile).

### Changed

- **`memory/.nyann/bootstraps/`** is the canonical location for boot records. Fits the existing "ephemeral team-shared scratch" framing of `memory/` (per `docs/principles/documentation.md`): committed by default so a teammate who pulls a bootstrap PR can also undo it; small enough that git churn is negligible. Teams that don't want them tracked can add a one-line gitignore.
- **`bin/boot-record.sh` field separator** is `\037` (Unit Separator) rather than tab. Bash's `read -r` with `IFS=$'\t'` collapses consecutive tabs because tab is a default-whitespace character, which silently ate empty middle fields and produced category-less write actions. US has no such collision.
- **`skills/retrofit/SKILL.md`** instructs the executor to pass `--source retrofit` when re-running bootstrap for remediation.
- **`schemas/preview-result.schema.json`** consumer note no longer mentions a "future undo-bootstrap" — undo-bootstrap consumes BootRecord, not PreviewResult.

### Fixes

- **`bin/preview.sh --json`** consumer documentation cleaned up (the v1.7.0 promise of "future tooling" is now realized via BootRecord, a separate contract).
- **Manifest portability across clones** (review-flagged P1) — `bin/undo-bootstrap.sh` no longer compares the manifest's recorded absolute path against `$target` exactly. A teammate who cloned the bootstrap PR into a different filesystem path was hitting "manifest target mismatch" even in the same repo. The new check verifies the manifest file lives under `$target` (which it must, when committed via `memory/.nyann/bootstraps/`); the original path field stays informational.
- **Newly-created hook files are now recorded** (review-flagged P1) — `nyann::br_register_post_dir` registers a directory whose contents are diffed against `tracked.tsv` at finalize time. `bin/bootstrap.sh` registers `.git/hooks` and `.husky` so files materialised by `install-hooks` (e.g., `.git/hooks/commit-msg` on a fresh repo) get a `create` write action even though they didn't exist pre-bootstrap. Without this, undo had nothing to delete.
- **Pre-flight refusals fire uniformly in preview AND `--yes` runs** (review-flagged P1) — the HEAD-ahead-of-seed and non-empty-branch refusal checks were gated on `!$effective_dry_run`, so a dry-run previewed as success and a `--yes` run then refused. That broke preview-before-mutate. Refusals now apply uniformly; the operator sees the same outcome in both modes.
- **`seed_commits_undone[]` only records actual undoes** (review-flagged P2) — the seed-commit always-skip path used to append the SHA to `seed_commits_undone[]` even though it left HEAD untouched. The result JSON now stays accurate: skipped seed commits appear in `skipped[]` only.
- **Path-traversal hardening in snapshot AND restore** (Gemini-flagged P1) — `nyann::br_snapshot` and `bin/undo-bootstrap.sh`'s write-action handlers both reject paths that escape the target. A malicious `plan.json` with `"path": "../../.ssh/id_rsa"` would previously have caused `cp` to copy SSH keys into `pre-state/` (which is committed by default), then a follow-up undo could have restored arbitrary content to the same path. Two layers of defense: a string-level check for `/` prefix and `..` segments, plus `nyann::path_under_target` to catch symlink-mediated escape (e.g., `dir/file` where `dir` is itself a symlink to `/etc`). The symlink check happens AFTER the existing leaf-symlink branch so legitimate symlinks at clean paths still get the irreversible-action treatment.
- **Symlink action preserves caller category** (Gemini-flagged P3 reclassed correctness) — `br_finalize_writes` used to hardcode `category:"hooks"` for symlink-marked rows, dropping whatever category the caller passed. The original category is now packed alongside the symlink marker and emitted on the action so `--scope` filtering works correctly for symlinked paths.
- **`cp` failures during snapshot are caught** (Gemini-flagged P2) — a single permission-denied or vanished file used to abort the entire bootstrap via errexit. `nyann::br_snapshot` now catches `cp` failure, decrements the blob counter, marks the row as `cpfail`, and `br_finalize_writes` emits a `reversible:false` action with `irreversible_reason:"could not snapshot pre-state (permission or vanished file)"` so undo refuses cleanly rather than restoring incorrect content.
- **Tests for path-traversal refusal, symlink handling, corrupt-blob detection, and post-bootstrap user-edit-skipping** — closes coverage gaps Gemini surfaced. New tests in `test-bootstrap-manifest.bats` and `test-undo-bootstrap.bats`.
- **`--scope=` (empty string) no longer crashes under `set -u`** (bug-hunt P2) — `read -ra raw <<<"$scope"` leaves `raw` unbound on an empty input, so the `for s in "${raw[@]}"` loop died with a nounset error. The handler now uses `${raw[@]+...}` expansion, defaults `scope_csv` to the full set when nothing was parsed, and treats an empty `--scope=` value identically to `--scope=all`.
- **`br_snapshot` rejects paths with embedded newline or `\037`** (bug-hunt P2) — POSIX permits these characters but they would split `tracked.tsv` rows mid-stream and yield schema-invalid manifest entries. Refused early with a `br_snapshot:` warning, alongside the existing `..`/absolute traversal refusal.
- **Atomic `manifest.json` write** (bug-hunt P2) — `bin/boot-record.sh`'s `nyann::br_finalize` writes to `<dir>/.manifest.json.tmp` first, then `mv -f` into place. A concurrent reader can no longer observe a half-written file, and a `jq` failure during finalize leaves the previous (or no) manifest in place rather than a truncated one.
- **Finalize errors no longer silently swallowed** (bug-hunt P2) — `bin/bootstrap.sh`'s two `br_finalize` call sites used to wrap the call in `2>/dev/null || true`, masking real failures (jq error, fs full, permission). They now capture stderr to a tempfile and dump it to the operator's stderr when finalize returns no manifest path. `nyann::br_finalize` itself returns non-zero on `jq` failure rather than continuing past a bad write.
- **Newest-manifest selection sorts by `created_at`** (bug-hunt P3) — `bin/undo-bootstrap.sh` no longer relies on `find | xargs ls -t` for tie-breaking. Two boot records produced in the same second used to pick non-deterministically based on filesystem traversal order; sorting by the manifest's ISO 8601 `created_at` field is stable and lexically correct.
- **`profile_sha256` is now canonicalised (`jq -Sc`)** (bug-hunt P3) — the schema documents both `profile_sha256` and `plan_sha256` as SHA-256 of the canonicalised JSON, but `br_init` was hashing the raw profile file (sensitive to whitespace and key order). Canonicalises both consistently now.
- **Plan-declared action enum is preserved through the manifest** (bug-hunt P3) — `br_finalize_writes` used to collapse every existed:true:true case to `action:"overwrite"`, even when the plan said `merge`. The plan-declared action is now passed via `nyann::br_snapshot`'s optional third argument, threaded through `tracked.tsv`, and emitted on the action so the `BootRecord.action` field actually mirrors `ActionPlan.writes[].action` as the schema documents.

## [1.7.0] — 2026-05-07

### Added

- **`bin/preview.sh --json`** — emits a single PreviewResult JSON object on stdout (plan + summary + plan_sha256 + skips_applied), no stderr render. Mutually exclusive with `--emit-sha256`. New `schemas/preview-result.schema.json` locks the shape; tooling consumers (and the future `undo-bootstrap.sh` deferred to v1.8) no longer need to scrape stderr. `--decision no` in JSON mode emits a structured declined payload (`{"declined": true, …}`) on stdout with rc 1, so callers can distinguish refusal from crash. `--skip` reports `skips_applied[]` containing only paths that actually matched a write in the unfiltered plan.
- **`bin/{compute-drift,retrofit,doctor}.sh --scope <csv>`** — narrow drift to one or more categories (`docs`, `hooks`, `branching`, `gitignore`, `editorconfig`, `github`, `history`, `all`). Operators who carefully tuned hooks but want to fix doc drift can now run `retrofit --scope docs` without scrolling past every hook entry in preview. `compute-drift.sh` and `bootstrap.sh` accept the same flag (defensive plan filtering). Unknown scope values exit non-zero with a clear error.
- **`DriftReport.scope_applied[]`** — new optional field. Default scope expands to the canonical 7-element list; narrower scopes contain only the categories the operator asked for. Documented in `schemas/drift-report.schema.json`. `health-trend.sh` / `doctor-ci.sh` consumers can compare against `length == 7` to distinguish "checked, no drift" from "not checked".
- **`bin/doctor.sh --scope` auto-skips `--persist`** — a partial-scope health score would corrupt the trend series in `memory/health.json`, so doctor warns + drops persist when scope is narrower than `all`. Operators can re-run with default `--scope=all` to refresh.
- **Visual diff in preview for merge actions** — `bin/preview.sh` now renders a unified diff for merge entries that carry a `preview_blob`. Default truncates to 20 lines per file (`--full-diff` for full hunks; `--no-diff` for legacy size-only display). Powered by:
  - **`bin/render-plan.sh`** — pre-renders merge content for `.gitignore` and `CLAUDE.md` to a tempdir, then rewrites the plan with `preview_blob` + `current_bytes` on each rendered entry.
  - **`bin/gitignore-combiner.sh --output <path>`** and **`bin/gen-claudemd.sh --output <path>`** — write-to-alternate-path mode. In-place semantics are unchanged. Refuses `--output == --target` (use the in-place form for that). Hook files and YAML configs stay pass-through (size-only) for v1.7.0; the two highest-anxiety merges were the wedge.
- **`bin/setup.sh --simulate <repo>`** — runs detect-stack → suggest-profile → recommend-branch → route-docs → plan-bootstrap → render summary against an arbitrary repo without touching anything. Strictly read-only: no `preferences.json` written, no target mutations. JSON mode emits a structured `SimulationResult` payload (`simulation`, `target`, `stack`, `profile`, `branching`, `plan`, `partial_reason`); text mode echoes "If you ran /nyann:bootstrap here…". Monorepos surface as `simulation: "partial"` with a one-line reason since per-workspace writes still live in the skill layer.
- **`bin/plan-bootstrap.sh`** — extracts ActionPlan composition from `skills/bootstrap-project/SKILL.md` step 5 into a reusable script. Composes writes[] from profile + DocumentationPlan + StackDescriptor following the same gating rules the skill documents (extras.gitignore, hooks-by-language, archetype-aware doc scaffolds, CI workflow, GitHub templates). Output validates against `schemas/action-plan.schema.json`. Today the bootstrap skill keeps its inline path for backward compatibility; the script primarily serves `--simulate` and is the cleaner long-term path.
- **Glossary auto-population** — closes the v1.7+ open question in `docs/principles/documentation.md` (the AI-retrieval-first promise of `glossary.md` only lands when the file has actual content). New **`bin/scaffold-glossary.sh`** detects exported top-level types per language (Go: `type X struct/interface`; TS: `export interface/type/class/enum`; Python: top-level `class`; Rust: `pub struct/trait/enum`; Java/Kotlin/Swift: `public`). Ranks by external reference count and caps at `--max-terms` (default 50). Marker-bracketed auto block (`<!-- nyann:glossary:auto-start -->` / `auto-end`) is regenerated idempotently; user content outside the markers is preserved.
- **`profile.documentation.glossary.{auto_populate,max_terms,languages}`** — opt-in profile fields. Default `auto_populate: false` preserves v1.6.0 behaviour for existing users. `bin/scaffold-docs.sh` accepts `--auto-glossary --glossary-max-terms --glossary-languages` and `bin/bootstrap.sh` forwards the resolved settings.
- **`schemas/glossary-draft.schema.json`** — output of `scaffold-glossary.sh --json` (terms[], languages, scanned_files, total_candidates, selected). Added to `schemas/README.md` (now 45 schemas).
- **`schemas/preview-result.schema.json`** — locks the `preview.sh --json` payload shape.
- **`writes[].preview_blob` and `writes[].current_bytes`** in `schemas/action-plan.schema.json` — optional fields populated by `render-plan.sh`. Bootstrap.sh tolerates them transparently; the SHA-256 binding still covers them.
- **`templates/docs/glossary.tmpl`** ships with the auto-block markers in place so a fresh scaffold lands at the right spot for `scaffold-glossary.sh` to populate.
- 4 new bats files — `test-preview-json.bats`, `test-retrofit-scope.bats`, `test-preview-diff.bats`, `test-setup-simulate.bats`, `test-scaffold-glossary.bats` (~63 new tests total).

### Changed

- **`skills/retrofit/SKILL.md`** — new section 3a documenting `--scope` mapping for the common user phrases ("only fix the docs", "leave my hooks alone"). New section 3b prompts via `AskUserQuestion` multiSelect when drift spans more than one category and the user hasn't pre-specified a scope. Step 5 wired to call `bin/render-plan.sh` before `bin/preview.sh` so retrofit's preview gets the same merge diff as bootstrap.
- **`skills/doctor/SKILL.md`** — documents `--scope` and the auto-disabled `--persist` behaviour.
- **`skills/bootstrap-project/SKILL.md`** — step 5 split into 5a (render merge previews) + 5b (preview). Section 4a-2 added: when scaffold set includes `glossary`, prompt the user to opt into auto-populate (default Yes for `library` and `api-service` archetypes).
- **`skills/setup/SKILL.md`** — new optional Step 3b inviting the user to run `bin/setup.sh --simulate "$PWD"` against the current repo before committing to `/nyann:bootstrap`.
- **`bin/_lib.sh`** — three new helpers: `nyann::scope_includes`, `nyann::valid_scope_csv`, `nyann::canonical_scope`. Single source of truth for the v1.7.0 scope category names; reused across compute-drift, retrofit, doctor, bootstrap.
- **`bin/scaffold-docs.sh`** — accepts `--auto-glossary`, `--glossary-max-terms`, `--glossary-languages`. When set and the resolved scaffold set includes `glossary`, calls `scaffold-glossary.sh` after writing the template seed.
- **`schemas/README.md`** — schemas table updated; new entries for `glossary-draft` and `preview-result`. ActionPlan producer column lists `bin/render-plan.sh` alongside the existing producers.

### Fixes

- **`bin/preview.sh` no longer prints stderr render in `--json` mode.** Tooling consumers parsing stdout JSON were previously forced to redirect stderr separately; the new mode emits a single self-contained payload.

## [1.6.0] — 2026-05-06

### Added

- **Project Memory** — nyann's documentation system has a named concept now. [`docs/principles/documentation.md`](docs/principles/documentation.md) defines the five properties (AI-retrieval-first, size-budgeted, drift-aware, storage-agnostic, dual-audience) and the layered model (`CLAUDE.md` router → `docs/` Project Memory → `memory/` ephemeral scratch). Every future doc-related feature is justified against this principles doc.
- **Codebase archetype detection** — `bin/detect-stack.sh` emits a new `archetype` field on the StackDescriptor: one of `api-service`, `cli-tool`, `library`, `web-app`, `mobile-app`, `plugin`, `unknown`. Detection uses signals already in the repo (OpenAPI/proto files, `package.json` `bin` field, `cmd/main.go`, server/frontend frameworks, `.claude-plugin/`, etc.). Profile-declared `archetype` overrides detection.
- **4 new doc templates** aligned to Project Memory principles:
  - `templates/docs/api-reference.tmpl` — endpoint catalog with bounded scope per endpoint, predictable structure
  - `templates/docs/runbook.tmpl` — operational playbook organized by *symptom* (not cause) so AI agents debugging outages retrieve naturally
  - `templates/docs/deployment.tmpl` — topology / pipeline / configuration / rollout, separated from architecture
  - `templates/docs/glossary.tmpl` — domain-term reference with definitions, invariants, and cross-links (the sleeper hit for AI second-brain disambiguation)
- **Per-archetype scaffold maps** — `bin/scaffold-docs.sh` maps each archetype to the right doc set: api-service → architecture+api-reference+runbook+deployment+adrs+glossary, cli-tool → architecture+runbook+adrs+glossary, library → architecture+api-reference+adrs+glossary, web-app/mobile-app → architecture+runbook+deployment+adrs+glossary, plugin → architecture+adrs+glossary, unknown → architecture+adrs (matches pre-v1.6.0 default).
- **`profile.archetype` and `profile.documentation.use_archetype_scaffolds`** — opt-in profile fields. When `use_archetype_scaffolds: true`, `bin/route-docs.sh` and `bin/scaffold-docs.sh` produce/consume the per-archetype expanded plan. Default is `false` — existing v1.5.x users see zero scaffold changes on upgrade.
- **`bin/route-docs.sh --archetype <name> --use-archetype-scaffolds`** — CLI flags so bootstrap and retrofit can drive archetype-aware planning without modifying the profile. Output `DocumentationPlan` carries `archetype` and `use_archetype_scaffolds` for downstream `scaffold-docs.sh` consumption.
- **Bootstrap archetype prompt** — `skills/bootstrap-project/SKILL.md` now prompts the user via `AskUserQuestion` when detection emits a non-`unknown` archetype, defaulting to "enable archetype-aware scaffolds (recommended)".
- **`bin/session-check.sh --flow=<commit|release|pr|ship>`** — flag that appends a flow-specific suffix ("(non-blocking — proceeding with the X flow.)") to the drift nudge. The four caller skills now pass `--flow` instead of duplicating an 8-line preamble each.
- 2 new schemas updated with archetype fields: `schemas/stack-descriptor.schema.json`, `schemas/documentation-plan.schema.json`. Profile schema (`profiles/_schema.json`) extended with top-level `archetype` and `documentation.use_archetype_scaffolds`.
- 6 new bats files: `test-claudemd-self-compliance.bats`, `test-memory-readme-content.bats`, `test-session-check-flow.bats`, `test-detect-archetype.bats`, `test-archetype-scaffolds.bats`, `test-templates-archetype.bats`.

### Changed

- **`templates/memory/README.tmpl` reframed** — drops the misleading "Session-scratch for Claude" framing that conflated nyann's `memory/` folder with Claude Code's per-user auto-memory (`~/.claude/projects/<encoded>/memory/`). Now positioned as the ephemeral team-shared scratch layer, distinct from Project Memory (`docs/`) and from Claude's auto-memory. Includes a layered-model table.
- **`bin/gen-claudemd.sh`** — memory paragraph reframed to match. Row labels added for new doc types (`api_reference`, `runbook`, `deployment`, `glossary`).
- **`bin/session-check.sh`** — `--flow=<verb>` argument added for skill callers. Unknown flow values rejected with rc 2.
- **`skills/{commit,release,pr,ship}/SKILL.md` § 0** — drift-check preamble trimmed from 8 lines to 2 (~370 B saved per skill, ~1.5 KB total). Future drift-check wording changes need 1 edit, not 4.
- **This repo's own `CLAUDE.md`** brought under the 3 KB router-mode soft cap (4748 B → 2333 B). "Architecture at a glance" extracted to [`docs/architecture.md`](docs/architecture.md); "Non-negotiable conventions" extracted to [`docs/principles/conventions.md`](docs/principles/conventions.md). CLAUDE.md is now a router into Project Memory, per its own rule.
- **`README.md`** — new "Project Memory" section with the five-property summary and a link to the principles doc. "Documentation routing" subsection rolled under it. Removed the "Roadmap" section (Shipped + Planned subsections); release history is in `CHANGELOG.md` and feature requests belong in GitHub issues, so the README no longer duplicates either.
- **`bin/route-docs.sh`** — accepts `--archetype` and `--use-archetype-scaffolds` flags; expanded path catalog covers the four new doc types; obsidian leaf-name mapping extended.
- **`bin/scaffold-docs.sh`** — reads `archetype` and `use_archetype_scaffolds` from the plan; expands targets via the archetype map when the flag is set; explicit `targets[]` entries override the map.
- **`skills/retrofit/SKILL.md`** — section 5 explains archetype-aware retrofit: when the profile sets `use_archetype_scaffolds: true`, missing per-archetype docs surface as drift. Retrofit does NOT auto-flip the flag — opt-in stays opt-in per the v1.6.0 design.
- **`skills/route-docs/SKILL.md`** — preview section mentions the four new archetype-aware doc types.

### Fixes

- nyann's own `doctor` audit no longer flags `CLAUDE.md` as `warn` — physician heal thyself.

## [1.5.1] — 2026-05-06

### Fixes

- surface progress + errors across ship/pr/release/doctor/sync (UX feedback) (#15) (844da84)
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

[1.12.0]: https://github.com/thettwe/nyann/releases/tag/v1.12.0
[1.11.0]: https://github.com/thettwe/nyann/releases/tag/v1.11.0
[1.10.0]: https://github.com/thettwe/nyann/releases/tag/v1.10.0
[1.9.0]: https://github.com/thettwe/nyann/releases/tag/v1.9.0
[1.8.0]: https://github.com/thettwe/nyann/releases/tag/v1.8.0
[1.7.0]: https://github.com/thettwe/nyann/releases/tag/v1.7.0
[1.6.0]: https://github.com/thettwe/nyann/releases/tag/v1.6.0
[1.5.1]: https://github.com/thettwe/nyann/releases/tag/v1.5.1
[1.5.0]: https://github.com/thettwe/nyann/releases/tag/v1.5.0
[1.4.0]: https://github.com/thettwe/nyann/releases/tag/v1.4.0
[1.3.0]: https://github.com/thettwe/nyann/releases/tag/v1.3.0
[1.2.1]: https://github.com/thettwe/nyann/releases/tag/v1.2.1
[1.2.0]: https://github.com/thettwe/nyann/releases/tag/v1.2.0
[1.1.2]: https://github.com/thettwe/nyann/releases/tag/v1.1.2
[1.1.1]: https://github.com/thettwe/nyann/releases/tag/v1.1.1
[1.1.0]: https://github.com/thettwe/nyann/releases/tag/v1.1.0
[1.0.0]: https://github.com/thettwe/nyann/releases/tag/v1.0.0