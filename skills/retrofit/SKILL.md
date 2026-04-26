---
name: retrofit
description: >
  Audit an existing repo against a profile and offer to fix what's drifted.
  TRIGGER when the user says "retrofit this repo", "fix this repo's hygiene",
  "bring this repo into compliance", "remediate drift", "fix what's drifted",
  "make this repo match the profile", "my repo is half set up, finish it",
  "I already have some hooks but they're incomplete", "fill in the gaps",
  "upgrade this repo to nyann standards", "apply the profile to this existing repo".
  ALSO trigger when doctor finishes with drift (exit 4 or 5) and the user says
  "fix it", "remediate", "yes fix those", "go ahead and fix".
  Do NOT trigger on "is this repo healthy" / "check hygiene" / "audit docs" —
  those are doctor (read-only). Do NOT trigger on "set up this project" from
  scratch — that's bootstrap-project.
---

# retrofit

Audit an existing repo's drift from a profile and remediate what's missing or
misconfigured. This is the "fix it" counterpart to doctor's "tell me what's
wrong."

## 1. Resolve the profile

Same logic as doctor — the audit is only meaningful against an intended
baseline:

1. Check if the repo's CLAUDE.md (inside `<!-- nyann:start -->` markers)
   declares an active profile name.
2. If the user passed `--profile <name>`, use that.
3. If neither, ask the user which profile to audit against. List available
   profiles (starters + any user/team profiles). Don't silently default —
   the wrong baseline produces misleading drift.

Load via `bin/load-profile.sh <name>`. If exit 2 (not found), show the
list the loader reports and ask again.

## 2. Run detection

Run `bin/detect-stack.sh --path <target>` to get the StackDescriptor. This
ensures the remediation step has stack context for gitignore templates, hook
phases, and CLAUDE.md rendering.

## 3. Run the drift audit

```
bin/retrofit.sh --target <cwd> --profile <resolved-name>
```

**Do not pass `--report-only`** — that's doctor's flag. Retrofit's default
mode renders the report AND offers remediation guidance.

Pass `--json` only if the user explicitly asks for machine-readable output.

## 4. Interpret the exit code

| Code | Meaning | What to do |
|---|---|---|
| 0 | clean | "No drift detected. Repo matches the profile." Done. |
| 4 | warnings | Show the report. Offer to remediate (step 5). |
| 5 | critical | Show the report. Strongly recommend remediation (step 5). |

## 5. Remediate

When drift exists (exit 4 or 5) and the user confirms they want to fix it:

1. **Build an ActionPlan** from the drift report. Map missing items to
   `writes[]` entries:
   - Missing `.gitignore` → gitignore combiner handles it
   - Missing `.husky/*`, `commitlint.config.js` → `install-hooks.sh --jsts`
   - Missing `.pre-commit-config.yaml` → `install-hooks.sh --python`
   - Missing `docs/*`, `memory/*` → `scaffold-docs.sh`
   - Missing/oversized `CLAUDE.md` → `gen-claudemd.sh`
   - Missing `.editorconfig` → include in plan if profile declares it

2. **Route docs** via `bin/route-docs.sh --profile <path>` to get the
   DocumentationPlan (needed by bootstrap for scaffold-docs and gen-claudemd).

3. **Preview** the plan via `bin/preview.sh --plan <file>`. Show the user
   what will be created/merged. Respect skip requests.

4. **Execute** via `bin/bootstrap.sh`. Capture the plan SHA-256 first
   via `bin/preview.sh --emit-sha256`,
   then pass it through as `--plan-sha256` so bootstrap can verify the
   plan bytes haven't changed between the user's confirmation and
   execution. The SHA binding is required; bootstrap refuses to run
   without it.
   ```
   sha=$(bin/preview.sh --plan <confirmed-plan.json> --emit-sha256)
   bin/bootstrap.sh \
     --target <cwd> \
     --plan <confirmed-plan.json> \
     --plan-sha256 "$sha" \
     --profile <path> \
     --doc-plan <doc-plan.json> \
     --stack <stack.json>
   ```
   Bootstrap is idempotent — existing user content is preserved, hooks are
   merged (not overwritten), gitignore entries are deduplicated.

5. **Re-run doctor** after remediation to confirm the drift is resolved.
   Show the before/after delta.

## 6. What retrofit does NOT do

- **History rewrites.** Non-compliant commits are flagged, never fixed.
  Tell the user: "Past commits are informational only. Future commits will
  be validated by the hooks we just installed."
- **Application scaffolding.** Retrofit adds git workflow infrastructure,
  not app code.
- **Dependency installation.** It writes hook configs but won't run
  `npm install` or `pip install`. Tell the user to run their package
  manager after retrofit.

## 7. Output summary

End with a compact report:

- Profile audited against.
- Drift found: N missing, N misconfigured, N non-compliant commits.
- Files created/merged (count).
- Hook phases run.
- Whether CLAUDE.md is now within budget.
- Remaining items that need manual attention (if any).

## When to hand off

- "Just tell me what's wrong, don't fix it" → hand off to `doctor`.
- "Set up from scratch" → hand off to `bootstrap-project`.
- "I want a different profile" → ask which one, then re-run retrofit
  with the new profile.
