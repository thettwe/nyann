---
name: gh-protect
description: >
  Audit or apply GitHub branch protection, tag rulesets, repo security
  settings, and signing requirements based on the active profile.
  TRIGGER when the user says "check branch protection", "audit GitHub
  protection", "apply branch protection", "enforce branch protection",
  "set up branch protection", "configure branch rules", "check tag
  protection", "audit repo security", "apply GitHub settings",
  "enable branch protection", "protection audit", "are my branches
  protected", "/nyann:gh-protect".
  Do NOT trigger on "is this repo healthy" — that's `doctor` (which
  includes a protection check among many other signals).
  Do NOT trigger on "bootstrap this project" — bootstrap applies
  protection as one step of the full pipeline.
---

# gh-protect

Standalone GitHub protection management. Wraps `bin/gh-integration.sh`
in two modes: `--check` (read-only audit) and apply (write). Lets
users manage branch protection, tag rulesets, signing requirements,
and repo-level merge settings independently of bootstrap or doctor.

## 1. Pre-flight

Guard on `gh`:
```
command -v gh && gh auth status
```
If either fails, tell the user `gh` is required for this skill and
stop. Unlike other skills that soft-skip, protection management has
no useful fallback without `gh`.

## 2. Resolve profile

Load the active profile the same way doctor does:
1. Check `~/.claude/nyann/preferences.json` for a profile name.
2. Fall back to CLAUDE.md markers.
3. Fall back to `"default"`.
4. Load via `bin/load-profile.sh <name>`.

If the user names a specific profile, use that instead.

## 3. Audit first (always)

Run the read-only check regardless of whether the user asked to audit
or apply — the delta informs what apply would change:

```
bin/gh-integration.sh --target <cwd> --profile <name> --check
```

Output conforms to `schemas/protection-audit.schema.json`. Show the
user a summary table:

| Area | Expected | Actual | Drift |
|---|---|---|---|
| Branch protection (`branches[]`) | from profile | from GitHub API | critical / warn / ok |
| Tag rulesets | `.github.tag_protection_pattern` | GitHub Rulesets API | critical / warn / ok |
| CODEOWNERS gate | `.github.require_code_owner_reviews` | branch protection | critical / warn / ok |
| Signing | `.github.require_signed_commits/tags` | branch protection + local git config | critical / warn / ok |
| Repo settings | `.github.allow_*_merge`, `delete_branch_on_merge` | repo API | warn / ok |
| Security signals | Dependabot, secret scanning, push protection, code scanning | repo API | info |

If everything is `ok`, report "protection matches profile" and stop
(no apply needed).

## 4. Offer to apply (if drift found)

If any drift exists at `critical` or `warn` level, ask:

"Apply protection rules to match the profile? This will update
branch protection via the GitHub API."

On confirmation:
```
bin/gh-integration.sh --target <cwd> --profile <name>
```

The apply mode never downgrades stricter remote rules — it only
tightens. Relay this constraint so the user understands that loosening
protection requires manual GitHub UI changes.

Output is a GhIntegrationResult JSON
(`schemas/gh-integration-result.schema.json`). Report:
- `applied[]` — rules that were created or updated.
- `noop[]` — rules already at or above the expected level.
- `errors[]` — rules that failed to apply (permission issues, etc.).

## 5. Report

After audit-only or audit+apply, end with:
- Protection status per branch (protected / unprotected / partial).
- Tag ruleset status.
- Any `errors[]` that need manual attention.

## When to hand off

- "Check overall repo health" → `doctor` skill (includes protection
  as one signal among many).
- "Set up this repo from scratch" → `bootstrap-project` skill (applies
  protection as part of the full pipeline).
- "I changed my profile's GitHub settings" → re-run this skill to
  apply the updated expectations.
- "Loosen a protection rule" → explain that `gh-integration.sh` never
  downgrades; the user must change the rule via the GitHub UI or API
  directly.
