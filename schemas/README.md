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

## Schemas in this directory (39)

| Schema | Producer(s) | Consumer(s) |
|---|---|---|
| `action-plan.schema.json` | composed by skills + `bin/preview.sh` | `bin/bootstrap.sh` |
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
| `gh-integration-result.schema.json` | `bin/gh-integration.sh` | `bin/bootstrap.sh`, `bin/retrofit.sh`, skill layer |
| `health-score.schema.json` | `bin/compute-health-score.sh` | `bin/persist-health-score.sh`, `bin/doctor.sh` |
| `hotfix-result.schema.json` | `bin/hotfix.sh` | `skills/hotfix/SKILL.md` |
| `link-check-report.schema.json` | `bin/check-links.sh` | `bin/compute-drift.sh` |
| `mcp-doc-targets.schema.json` | `bin/detect-mcp-docs.sh` | `bin/route-docs.sh` |
| `mcp-registry.schema.json` | `templates/mcp-registry.json` data file | `bin/detect-mcp-docs.sh` |
| `migration-plan.schema.json` | `bin/switch-profile.sh --json` | `skills/migrate-profile/` |
| `orphan-report.schema.json` | `bin/find-orphans.sh` | `bin/compute-drift.sh` |
| `pr-result.schema.json` | `bin/pr.sh` | `skills/pr/SKILL.md` |
| `preferences.schema.json` | written by `bin/setup.sh` | `bin/session-check.sh`, etc. |
| `pr-checks-result.schema.json` | `bin/wait-for-pr-checks.sh` | `skills/wait-for-pr-checks/SKILL.md`, `bin/release.sh --wait-for-checks`, `bin/ship.sh` |
| `prereqs-report.schema.json` | `bin/check-prereqs.sh --json` | `skills/check-prereqs/SKILL.md`, `bin/setup.sh` |
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
| `undo-result.schema.json` | `bin/undo.sh` | `skills/undo/SKILL.md` |
| `version-recommendation.schema.json` | `bin/recommend-version.sh` | `skills/release/SKILL.md` |
| `workspace-configs.schema.json` | `bin/resolve-workspace-configs.sh` | `bin/bootstrap.sh`, `bin/gen-codeowners.sh` |

### Cross-referenced schemas (live elsewhere)

| Schema | Producer(s) | Consumer(s) |
|---|---|---|
| `profiles/_schema.json` | hand-authored profile files | `bin/load-profile.sh`, `bin/validate-profile.sh` |

Every schema in the in-directory table has a producer→validate regression in
`tests/bats/test-schema-validation.bats`. When you add a new schema,
add the regression too — the public-surface count test asserts that
every schema is documented here, and adding the producer column without
the matching bats case will surface in code review.
