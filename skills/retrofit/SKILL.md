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

### 3a. Narrow scope (v1.7.0+)

If the user said something like "only fix the docs drift", "leave my
hooks alone", "just the gitignore", or otherwise wants to remediate
one part of the audit without touching others, pass `--scope <csv>`
to retrofit:

| User intent | `--scope` |
|---|---|
| "fix only the docs" | `docs` |
| "fix hooks but leave docs alone" | `hooks` |
| "fix the gitignore" | `gitignore` |
| "fix only docs and hooks" | `docs,hooks` |
| "fix the github protection settings" | `github` |
| "fix everything" / unstated | omit (default `all`) |

The accepted categories are `docs`, `hooks`, `branching`, `gitignore`,
`editorconfig`, `github`, `history`, `all`. Unknown values exit
non-zero; surface the error to the user verbatim.

When the report covers fewer than the full 7 categories, the rendered
text adds a `Scope: <csv>` line under the heading. The remediation
plan in step 5 uses the same `--scope` so that bootstrap only writes
the matching files.

### 3b. Multi-category prompt (when scope is unstated)

If the user did NOT specify a scope AND the resulting report shows
drift in more than one category, prompt before remediation:

```json
{
  "questions": [{
    "question": "Drift detected across multiple categories. Which to fix?",
    "header": "Scope",
    "multiSelect": true,
    "options": [
      {"label": "Docs",        "description": "CLAUDE.md size, doc scaffolds, links, orphans, staleness"},
      {"label": "Hooks",       "description": "Husky, commitlint, pre-commit.com, core hooks"},
      {"label": "Gitignore",   "description": "Missing stack-typical entries"},
      {"label": "Branching",   "description": "Profile-declared base/long-lived branches"},
      {"label": "GitHub",      "description": "CI workflow, PR template, branch + tag protection"},
      {"label": "Editorconfig","description": ".editorconfig presence"},
      {"label": "All",         "description": "Apply every remediation"}
    ]
  }]
}
```

Map the labels back to the `--scope` value: e.g. {Docs, Hooks} →
`docs,hooks`. If the user picks "All", omit the flag.

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

   **Archetype-aware retrofit (v1.6.0+):** if the profile sets
   `documentation.use_archetype_scaffolds: true`, the resolved
   DocumentationPlan will include the per-archetype doc set
   (api-reference / runbook / deployment / glossary as applicable).
   `compute-drift` will surface any missing files from that set as
   `missing` entries, and remediation will scaffold them.

   When the profile leaves `use_archetype_scaffolds` unset/false,
   retrofit does NOT auto-flip it. Per the v1.6.0 design, opt-in
   stays opt-in — surface the absent flag as informational only:
   "This profile could enable archetype-aware scaffolds. Run
   `/nyann:migrate-profile` or set `use_archetype_scaffolds: true`
   in your profile to opt in."

3. **Render merge previews** via `bin/render-plan.sh --plan <plan.json>
   --target <cwd> --profile <profile.json> --doc-plan <doc-plan.json>
   --templates-csv <jsts|python|...> --output <plan.rendered.json>`
   so `preview.sh` can diff `.gitignore` and `CLAUDE.md` merges against
   the current files. Skip render-plan only when neither path appears
   as a merge action in the plan.

4. **Preview** the rendered plan via `bin/preview.sh --plan <plan.rendered.json>
   --target <cwd>`. Pass `--target` so the merge-diff renderer
   resolves `.path` entries against the actual repo. Show the user
   what will be created/merged. Respect skip requests.

5. **Execute** via `bin/bootstrap.sh`. Capture the plan SHA-256 first
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

6. **Re-run doctor** after remediation to confirm the drift is resolved.
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
