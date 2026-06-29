# nyann JSON schemas

This directory holds the JSON-Schema (draft 2020-12) contracts for every
JSON shape that crosses a layer boundary in nyann — between subsystems,
between subsystems and orchestrators, and between orchestrators and the
skill layer.

If a `bin/*.sh` script writes JSON to stdout that any other script (or
the skill layer) parses, that JSON shape **should** have a schema here.
A regression test in `tests/bats/test-schema-validation.bats` pipes each
producer's output through the corresponding schema so a silent field
rename surfaces immediately.

## Versioning policy

Every schema's `$id` is `https://nyann.dev/schemas/<name>/v1.json`. The
URL is reserved (we don't host content there); it is purely a stable
identifier consumers can pin against.

- **`v1` is frozen.** No backwards-incompatible changes — adding optional
  properties is fine; renaming, removing, or tightening required-set is not.
- **Breaking changes ship under `v2`** at `/v2.json`. The producer keeps
  emitting v1 for a parallel-reader period (typically one minor release)
  so existing consumers don't break. After the deprecation window, the v1
  emit path is removed.
- A producer that needs to emit a brand-new shape introduces a fresh
  schema with `$id` `/v1.json` rather than versioning an existing one.

## Schemas in this directory (69)

| Schema | Producer(s) | Consumer(s) |
|---|---|---|
| `action-plan.schema.json` | composed by skills + `bin/preview.sh` (+ `bin/render-plan.sh`) | `bin/bootstrap.sh` |
| `boot-record.schema.json` | `bin/bootstrap.sh`, `bin/retrofit.sh` (writes `memory/.nyann/bootstraps/<ts>/manifest.json`) | `bin/undo-bootstrap.sh`, `skills/undo-bootstrap/SKILL.md` |
| `branching-choice.schema.json` | `bin/recommend-branch.sh` | `bin/bootstrap.sh`, skill layer |
| `claudemd-analysis.schema.json` | `bin/analyze-claudemd-usage.sh` | `bin/optimize-claudemd.sh`, `skills/optimize-claudemd/SKILL.md` |
| `claudemd-size-report.schema.json` | `bin/check-claude-md-size.sh` | `bin/compute-drift.sh` |
| `claudemd-usage.schema.json` | `bin/track-claudemd-usage.sh` | `bin/analyze-claudemd-usage.sh` |
| `cleanup-branches-result.schema.json` | `bin/cleanup-branches.sh` | `skills/cleanup-branches/SKILL.md` |
| `commit-context.schema.json` | `bin/commit.sh` | `skills/commit/SKILL.md` |
| `commit-result.schema.json` | `bin/try-commit.sh` | `skills/commit/SKILL.md` |
| `config.schema.json` | written by `bin/setup.sh` / `bin/add-team-source.sh` | `bin/sync-team-profiles.sh` |
| `diagnose-bundle.schema.json` | `bin/diagnose.sh --json` | maintainer-side support flow; `skills/diagnose/SKILL.md` |
| `documentation-plan.schema.json` | `bin/route-docs.sh` | `bin/bootstrap.sh`, `bin/scaffold-docs.sh` |
| `drift-report.schema.json` | `bin/compute-drift.sh` | `bin/retrofit.sh`, `bin/doctor.sh`, `bin/session-check.sh` |
| `drift-narrative.schema.json` | `bin/explain-diff.sh --format json` | `skills/explain-diff/SKILL.md`, `bin/doctor.sh --explain` (markdown path) |
| `dependency-updater-config.schema.json` | hand-authored input contract for `bin/gen-dependency-updater.sh` | `skills/gen-dependency-updater/SKILL.md`, future `bin/plan-bootstrap.sh` integration |
| `devcontainer-config.schema.json` | hand-authored input contract for `bin/gen-devcontainer.sh` | `skills/gen-devcontainer/SKILL.md`, future `bin/plan-bootstrap.sh` integration |
| `gh-integration-result.schema.json` | `bin/gh-integration.sh` | `bin/bootstrap.sh`, `bin/retrofit.sh`, skill layer |
| `glossary-draft.schema.json` | `bin/scaffold-glossary.sh --json` | `bin/scaffold-docs.sh`, skill layer |
| `governance-ci-result.schema.json` | `bin/doctor-ci.sh` | governance-check workflow, `skills/gen-ci/SKILL.md` |
| `health-score.schema.json` | `bin/persist-health-score.sh` (writes `memory/health.json`) | `bin/doctor.sh`, `bin/health-trend.sh` |
| `health-trend.schema.json` | `bin/health-trend.sh` | `skills/doctor/SKILL.md` |
| `hotfix-result.schema.json` | `bin/hotfix.sh` | `skills/hotfix/SKILL.md` |
| `link-check-report.schema.json` | `bin/check-links.sh` | `bin/compute-drift.sh` |
| `mcp-doc-targets.schema.json` | `bin/detect-mcp-docs.sh` | `bin/route-docs.sh` |
| `mcp-registry.schema.json` | `templates/mcp-registry.json` data file | `bin/detect-mcp-docs.sh` |
| `migration-plan.schema.json` | `bin/switch-profile.sh --json` | `skills/migrate-profile/` |
| `orphan-report.schema.json` | `bin/find-orphans.sh` | `bin/compute-drift.sh` |
| `pr-result.schema.json` | `bin/pr.sh` | `skills/pr/SKILL.md` |
| `preferences.schema.json` | written by `bin/setup.sh` | `bin/session-check.sh`, etc. |
| `preview-result.schema.json` | `bin/preview.sh --json` | tooling consumers |
| `pr-checks-result.schema.json` | `bin/wait-for-pr-checks.sh` | `skills/wait-for-pr-checks/SKILL.md`, `bin/release.sh --wait-for-checks`, `bin/ship.sh` |
| `prereqs-report.schema.json` | `bin/check-prereqs.sh --json` | `skills/check-prereqs/SKILL.md`, `bin/setup.sh` |
| `profile-diff.schema.json` | `bin/diff-profile.sh` | `skills/diff-profile/SKILL.md` |
| `profile-suggestion.schema.json` | `bin/suggest-profile.sh` | `skills/bootstrap-project/SKILL.md` |
| `protection-audit.schema.json` | `bin/gh-integration.sh --check` | `bin/doctor.sh`, `skills/doctor/SKILL.md` |
| `release-result.schema.json` | `bin/release.sh` | `skills/release/SKILL.md` |
| `setup-status.schema.json` | `bin/setup.sh --json` (and `--check --json`) | `skills/setup/SKILL.md`, `skills/bootstrap-project/SKILL.md` |
| `ship-result.schema.json` | `bin/ship.sh` | `skills/ship/SKILL.md` |
| `stack-descriptor.schema.json` | `bin/detect-stack.sh` | `bin/bootstrap.sh`, `bin/route-docs.sh` |
| `stale-branches-report.schema.json` | `bin/check-stale-branches.sh` | `bin/doctor.sh`, `bin/cleanup-branches.sh` |
| `staleness-report.schema.json` | `bin/check-staleness.sh` | `bin/compute-drift.sh` |
| `state-summary.schema.json` | `bin/explain-state.sh --json` | `skills/explain-state/SKILL.md` |
| `suggestions.schema.json` | `bin/suggest-profile-updates.sh` | `skills/suggest/SKILL.md` |
| `sync-result.schema.json` | `bin/sync.sh` | `skills/sync/SKILL.md` |
| `team-drift-report.schema.json` | `bin/check-team-drift.sh` | `bin/check-team-staleness.sh`, `skills/sync-team-profiles/SKILL.md` |
| `team-sync-result.schema.json` | `bin/sync-team-profiles.sh` | `skills/sync-team-profiles/SKILL.md` |
| `undo-bootstrap-result.schema.json` | `bin/undo-bootstrap.sh` | `skills/undo-bootstrap/SKILL.md` |
| `undo-result.schema.json` | `bin/undo.sh` | `skills/undo/SKILL.md` |
| `version-recommendation.schema.json` | `bin/recommend-version.sh` | `skills/release/SKILL.md` |
| `workspace-configs.schema.json` | `bin/resolve-workspace-configs.sh` | `bin/bootstrap.sh`, `bin/gen-codeowners.sh` |
| `workspace-release-result.schema.json` | `bin/release/release-workspace.sh` | `bin/release.sh --workspace`, `skills/release/SKILL.md` |
| `pr-risk-score.schema.json` | `bin/pr-risk-score.sh` | `bin/ship.sh`, `skills/ship/SKILL.md` |
| `team-profile-changelog.schema.json` | element shape of `team-sync-result`'s `updates_available[]` (nested by `bin/sync-team-profiles.sh --check-updates`; mirrored inline in `team-sync-result.schema.json`) | `skills/sync-team-profiles/SKILL.md` |
| `commit-hygiene.schema.json` | `bin/commit-hygiene.sh` | `skills/commit/SKILL.md` |
| `dead-code-scan.schema.json` | `bin/dead-code-scan.sh` | `bin/commit-hygiene.sh`, `bin/pre-action-guard.sh` |
| `docs-drift-report.schema.json` | `bin/docs-drift-scan.sh` | `skills/doctor/SKILL.md` (advisory section in the planned doctor integration), `bin/retrofit.sh --scope docs-drift` (planned auto-fix path) |
| `iac-drift-report.schema.json` | `bin/iac-drift-scan.sh` (orchestrates `bin/iac-drift/{unpinned-refs,missing-lockfile,secrets-in-vars,version-lag}.sh`) | `bin/doctor.sh` (IAC DRIFT sibling probe), `bin/guards/{unpinned-iac-refs,committed-secrets}.sh`, `skills/doctor/SKILL.md` |
| `iac-plan.schema.json` | `bin/iac-plan.sh` (dispatches to `bin/iac-plan/<tool>.sh` adapters; normalizes terraform `show -json` / pulumi `preview --json` / cdk diff into a common summary) | `bin/iac-apply.sh` (the gated apply reads the plan summary), `skills/iac-plan/SKILL.md` |
| `iac-apply-record.schema.json` | `bin/iac-apply.sh` (writes `memory/.nyann/iac-applies/<ts>/manifest.json` after gates pass — NO credentials/state) | audit trail; `skills/iac-apply/SKILL.md` |
| `docs-staleness.schema.json` | `bin/docs-staleness.sh` | `bin/session-triage.sh` (folds into the session-start summary), `skills/doctor/SKILL.md` (planned doctor integration) |
| `guard-result.schema.json` | `bin/pre-action-guard.sh` | `skills/commit/SKILL.md`, `skills/pr/SKILL.md`, `skills/release/SKILL.md`, `skills/ship/SKILL.md` |
| `coverage-baseline.schema.json` | `bin/guards/coverage-delta.sh --update-baseline` (writes `.nyann/coverage-baseline.json`) | `bin/guards/coverage-delta.sh` (guard mode reads the baseline) |
| `notification.schema.json` | `bin/ci-sentinel.sh` | `bin/read-notifications.sh`, `bin/session-triage.sh` |
| `notification-delivery-config.schema.json` | shape of `preferences.json` `notifications.delivery` (mirrored inline in `preferences.schema.json`) | `bin/notify-deliver.sh`, `bin/settings.sh`, `skills/settings/SKILL.md` |
| `readme-badge-block.schema.json` | `bin/gen-readme-badges.sh`, `bin/gen-readme-stack-icons.sh` | `bin/scaffold-docs.sh`, `bin/retrofit.sh` |
| `sentinel-state.schema.json` | `bin/ci-sentinel.sh` (state cache) | `bin/ci-sentinel.sh` (next-poll dedup) |
| `watch-list.schema.json` | `bin/sentinel-aggregate.sh` (`--add`/`--remove`/`--list`) | `bin/sentinel-aggregate.sh` (`--poll`), `bin/read-notifications.sh --all` |
| `session-triage.schema.json` | `bin/session-triage.sh` (reserved JSON variant) | future `--json` consumer |
| `derived-codeowners.schema.json` | `bin/derive-codeowners.sh` | `bin/gen-codeowners.sh --derived-owners` |

### Cross-referenced schemas (live elsewhere)

| Schema | Producer(s) | Consumer(s) |
|---|---|---|
| `profiles/_schema.json` | hand-authored profile files | `bin/load-profile.sh`, `bin/validate-profile.sh` |

Every schema in the in-directory table has a producer→validate regression in
`tests/bats/test-schema-validation.bats`. When you add a new schema,
add the regression too — the public-surface count test asserts that
every schema is documented here, and adding the producer column without
the matching bats case will surface in code review.
