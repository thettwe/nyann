---
name: gen-ci
description: "Generate GitHub Actions CI workflows for this repository. TRIGGER ON: 'generate CI', 'add GitHub Actions', 'create CI workflow', 'set up CI', 'add CI/CD', 'create a CI pipeline', 'generate CI/CD', 'add continuous integration', 'set up GitHub Actions', 'add a lint+test workflow', 'add governance check', 'add PR health check', 'add drift check to CI', 'set up governance gate', 'enforce governance in CI'. Generates .github/workflows/ci.yml with lint, typecheck, and test jobs, and optionally .github/workflows/governance-check.yml with drift + health-score PR gating."
---

# gen-ci — Generate GitHub Actions CI Workflow

You are the gen-ci skill. You generate a GitHub Actions CI workflow that mirrors the project's quality gates (lint, typecheck, test) based on the detected stack and nyann profile.

## When to trigger

- User asks to generate CI, add GitHub Actions, create a CI workflow, or set up CI/CD
- User asks to add continuous integration, create a pipeline, or add a lint+test workflow
- User asks to add a governance check, PR health check, drift check to CI, or governance gate
- User is bootstrapping a new project and wants CI

**DO NOT trigger on:** general questions about CI/CD concepts, debugging existing workflows not managed by nyann, or requests to modify workflows outside nyann markers.

## Execution flow

### Phase 1: Detect stack and resolve profile

1. Run `bin/detect-stack.sh --path .` to get a StackDescriptor JSON.
2. Resolve the active profile:
   - Check `~/.claude/nyann/preferences.json` for a profile name
   - Fall back to CLAUDE.md markers (`<!-- nyann:start -->` block → profile name)
   - Fall back to `"default"`
3. Load the profile via `bin/load-profile.sh <profile-name>` (the name is a positional argument).

### Phase 2: Preview the workflow

4. Run `bin/gen-ci.sh --profile <profile> --stack <stack> --target . --dry-run` to preview the generated workflow.
5. Show the user what will be generated:
   - Template selected (typescript/python/go/rust/generic)
   - Jobs and steps (lint, typecheck, test)
   - Package manager and version matrix
   - Path filters (if monorepo)

### Phase 2.5: Offer governance check

If the profile has a `governance` block, or if the user mentioned
"governance", "health check", or "drift check", offer to also
generate the governance-check workflow:

> "Also generate a governance check that runs doctor on every PR
> and posts a health report comment? (adds `governance-check.yml`)"

If the user accepts (or originally asked for it), add `--governance`
to the gen-ci.sh invocation.

### Phase 3: Confirm and write

6. Ask the user: "Write this CI workflow to `.github/workflows/ci.yml`?"
7. On confirmation, run:
   ```
   bin/gen-ci.sh --profile <profile> --stack <stack> --target . [--governance]
   ```
8. Report what was written (ci.yml, and governance-check.yml if `--governance`).

### Phase 4: Suggest next steps

9. Suggest:
   - "Run `/nyann:gen-templates` to add PR and issue templates"
   - "Run `/nyann:doctor` to check overall repo health"
   - If governance was generated: "Add a `governance` block to your
     profile to customize threshold and severity"
   - "Commit and push to see the workflow run"

## Key constraints

- The generated workflow uses marker comments (`# nyann:ci:start` / `# nyann:ci:end`). Regeneration replaces only the marked region; user content outside markers is preserved.
- If the profile has `ci.enabled: false`, explain that CI generation is disabled in the profile and offer to enable it.
- If `.github/workflows/ci.yml` already exists with nyann markers, inform the user it will be regenerated (not duplicated).
- If `.github/workflows/ci.yml` exists WITHOUT markers, the script refuses by default — it warns and skips so user-written CI isn't accidentally clobbered. Pass `--allow-merge-existing` to gen-ci.sh to opt in to appending the marked block (existing content is preserved above the markers). Suggest manual cleanup either way if the result isn't what the user wants.

## Error handling

- No stack detected → use `generic.yml` template, warn that lint/test steps are placeholders
- No profile found → use `default` profile (CI disabled by default — offer to enable)
- Template file missing → die with error pointing to `templates/ci/` directory

## Governance check details

The `--governance` flag generates `.github/workflows/governance-check.yml`:
- Runs `bin/doctor-ci.sh` on every PR against base branches
- Posts a health-score summary as a PR comment (updated on re-push)
- Blocks or warns based on the profile's `governance.threshold` (default 70)
- Emits GitHub Actions annotations for missing files, misconfigured hooks, etc.

Profile governance configuration (optional — all fields have defaults):
```json
{
  "governance": {
    "enabled": true,
    "threshold": 70,
    "severity": "block",
    "ignore": ["orphans", "stale"]
  }
}
```

| Field | Default | Effect |
|---|---|---|
| `enabled` | `true` | Set `false` to disable governance check generation |
| `threshold` | `70` | Minimum health score (0-100) to pass the gate |
| `severity` | `"block"` | `block` = fail check; `warn` = annotate only; `off` = skip |
| `ignore` | `[]` | Categories excluded from score (e.g. `orphans`, `stale`) |

## When to hand off

- "Add PR and issue templates too" → `gen-templates` skill.
- "Check repo health" → `doctor` skill.
- "Apply branch protection" → `gh-protect` skill.
- "Customize the governance threshold" → edit the profile's `governance` block.
- "Commit and ship" → `commit` skill, then `ship` skill.
