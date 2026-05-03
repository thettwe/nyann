---
name: bootstrap-project
description: >
  Bootstrap a fresh or existing repo with nyann. TRIGGER when the user says "set up this project",
  "initialize git workflow", "bootstrap this repo", "scaffold this project", "ngyamm this repo",
  "use my <name> profile" / "apply the nextjs-prototype profile" (profile mode).
  ALSO trigger on "standard setup" / "usual stack" / "the usual setup" /
  "install all the standard hooks" / "give this repo the usual setup" /
  "make this repo standard" / "install nyann" — these read as opinionated bulk setup,
  not narrow edits, even though they sound small.
  Also trigger on any phrasing that mentions wiring up git hooks + branching +
  conventions + docs as a single opinionated setup. DO NOT trigger on narrow requests
  like "add a lint hook" or "update CLAUDE.md" — those are edits, not bootstraps.
  DO NOT trigger on "audit this project" / "fix what's drifted" / "bring into compliance" —
  those are retrofit. DO NOT trigger on "check this project's health" / "is this healthy" —
  those are doctor.
  When in doubt, run the detection step and ask.
---

# bootstrap-project

You are executing nyann's main bootstrap flow. The goal is to take an empty directory, a fresh
repo, or an existing messy repo and bring it up to the conventions in a nyann profile — without
silently mutating anything.

**Work in phases.** Each phase is one or more bash scripts in `bin/`. Never run a destructive
action outside a preview-confirmed plan. If a phase emits a structured skip record
(`{"skipped": "...", "reason": "..."}`), log it in your final summary and continue with the
remaining phases.

## 0. Team profile freshness check (quick, non-blocking)

Run `bin/check-team-staleness.sh` before starting. If it produces
output, show the notification to the user (e.g. "Your team profiles
have upstream changes. Run `/nyann:sync-team-profiles` to update
before bootstrapping, or continue with the current versions.").
Do not block — let the user decide whether to sync first.

## 1. Detect

1. Run `bin/detect-stack.sh --path <target>` and capture the JSON to a temp file
   (e.g. `bin/detect-stack.sh --path <target> > "${TMPDIR:-/tmp}/nyann-stack.json"`)
   so step 2 can pass it via `--stack`. Never proceed without it.
2. If `confidence < 0.6`, tell the user what you found and ask them to confirm the stack before
   continuing. Show the top two or three reasoning entries so they can see *why* you chose what
   you chose.
3. If `is_monorepo` is true, note it — bootstrap will auto-resolve per-workspace configs
   (hooks, lint-staged entries, commit scopes) using `bin/resolve-workspace-configs.sh`.

See `references/python.md` and `references/javascript.md` for stack-specific notes Claude should
fold into its follow-ups. Only load them when the detected stack matches.

## 2. Pick a profile

Three branches:

- **User named a profile.** Load it with `bin/load-profile.sh <name>`. If the loader exits 2
  (profile not found), list the available profiles it reported and ask the user to pick one.
- **No profile named.** Run `bin/suggest-profile.sh --target <repo> --stack <stack-json-file>`
  to get a ranked list of matching profiles with confidence scores. Pass the StackDescriptor
  JSON captured in step 1 via `--stack` so the script reuses it instead of re-running
  detect-stack.sh (which would duplicate the directory walk).

  Show the user the top suggestion (or top 2-3 if scores are close):
  > "Detected: TypeScript + Next.js. Suggested profile: `nextjs-prototype` (confidence: 90).
  > Use this profile?"

  Rules:
  - If the top suggestion has confidence ≥ 70, propose it directly.
  - If the top suggestion has confidence 40-69, propose it but ask the user to confirm.
  - If no suggestion has confidence ≥ 40, fall back to `default` — **warn the user**
    because `default` means "skip all stack-specific hooks".
  - If suggestions is empty (no matches at all), use `default` with the same warning.

  **Multi-stack repos:** If `secondary_suggestions` is non-empty, the repo has
  secondary languages (e.g., a Python backend + React frontend). After applying
  the primary profile, mention the secondary stacks:
  > "This repo also has TypeScript code. For that portion, `nextjs-prototype`
  > would be the best match. Per-workspace profiles aren't supported yet, but
  > you can run `/nyann:diff-profile` to compare."
- **Audit mode** ("check hygiene", "is this healthy"). Invoke the `doctor` skill instead.
- **Retrofit mode** ("fix what's drifted", "bring into compliance"). Invoke the `retrofit`
  skill instead — it handles audit + remediation for existing repos.

## 3. Recommend branching (unless the profile already pins one)

1. Pipe the StackDescriptor into `bin/recommend-branch.sh`.
2. If `needs_user_confirm` is true, show the three top reasoning strings and ask the user to
   confirm before writing the strategy into the plan.
3. Otherwise, feed the recommendation straight into the action plan.

## 4. Route docs

1. Run `bin/detect-mcp-docs.sh` to discover Obsidian / Notion connectors. Capture the JSON.
2. If `available[]` is empty, run `bin/route-docs.sh --profile <path>` with no routing flags —
   plan is local-only.
3. If any MCP connector is available, load `references/mcp-routing.md` and walk the user through
   local vs MCP vs split. It covers the questions to ask, how to compose the `--routing` string,
   the connector-target inputs (`--obsidian-vault`, `--obsidian-folder`, `--notion-parent`),
   and the post-route creation flow (MCP tool calls per non-local target + plan update with
   returned identifiers).

Capture the resulting `DocumentationPlan`. `memory/` stays local by invariant regardless of
any routing choice.

## 5. Build and preview the plan

Compose an ActionPlan JSON from the profile + StackDescriptor + DocumentationPlan + BranchingChoice.
The shape:

```json
{
  "writes":   [{ "path": "...", "action": "create|merge|overwrite", "bytes": 123 }],
  "commands": [{ "cmd": "git init", "cwd": "." }],
  "remote":   []
}
```

**Required writes[] entries** — include each one the profile/plan opts into; bootstrap.sh will
refuse to materialise a file that isn't in this list (preview-before-mutate):

- `.gitignore` — when gitignore templates apply
- `.editorconfig` — when `profile.extras.editorconfig == true`
- `CLAUDE.md` — when `profile.extras.claude_md == true`
- `.husky/pre-commit`, `.husky/commit-msg`, `commitlint.config.js` — for JS/TS hook phase
- `.pre-commit-config.yaml` — for Python hook phase
- `.git/hooks/commit-msg`, `.git/hooks/pre-commit` — always for core hooks
- Doc files per DocumentationPlan (`docs/architecture.md`, `docs/prd.md`,
  `docs/decisions/ADR-000-…md`, `docs/research/README.md`) — when the profile's
  `documentation.scaffold_types` declares them

Pipe the plan through `bin/preview.sh --plan <file>`. Show the stderr preview to the user. If
they respond with `skip <path>`, re-invoke with `--skip <path>` and reshow. If `no`, stop and
exit.

## 6. Execute

Capture the plan SHA-256 first — `bin/preview.sh --plan <file> --emit-sha256` prints just the
hex on stdout. Pass it as `--plan-sha256` so bootstrap can recompute and verify the bytes
haven't changed between the user's "yes" and execution. The SHA binding is required;
bootstrap refuses to run without it.

```
sha=$(bin/preview.sh --plan <confirmed-plan.json> --emit-sha256)
bin/bootstrap.sh --plan <confirmed-plan.json> --plan-sha256 "$sha" \
  --target <repo> --profile <path> --doc-plan <path> --stack <path>
```

bootstrap.sh handles:

1. `git init` if needed.
2. Creating base branches per the strategy.
3. Writing files in the plan.
4. Running install commands (declared in the plan, never inferred).
5. Calling `bin/install-hooks.sh` with the matching phase flags (`--core`, `--jsts`, `--python`).
   For monorepos, also passes `--workspace-configs` (per-workspace lint-staged entries) and
   `--commit-scopes` (workspace-derived scopes for commitlint).
6. Calling `bin/scaffold-docs.sh` with the DocumentationPlan.
7. Calling `bin/gen-claudemd.sh` with profile + plan + stack.
   For monorepos, also passes `--workspace-configs` (renders Workspaces table) and
   `--extra-scopes` (merges workspace scopes into conventions table).

Every step is idempotent. On any failure, bootstrap.sh aborts cleanly with which step failed in
its summary; surface that verbatim. Do not retry automatically.

## 7. Offer the post-bootstrap nudges

After success, ask *only these three* — in order:

1. "Save this as a profile for reuse?" → if yes, ask for a profile name,
   then call `bin/learn-profile.sh --target <repo> --name <slug>`.
   Both `--target` and `--name` are required flags — never pass the name
   as a positional argument.
2. "Run `/nyann:doctor` now to audit?" → invoke the doctor skill. Pass the
   **bare profile name** (e.g. `python-cli`), not a filesystem path, as
   `--profile`. Doctor's `GITHUB PROTECTION` section will surface whether
   branch / tag protection is in place; tell the user they can re-run
   doctor anytime to verify protection state.
3. "Set up GitHub branch protection?" → invoke `bin/gh-integration.sh`
   (apply mode). For audit-only ("is protection drift on this repo?"),
   doctor already covers it via `bin/gh-integration.sh --check` —
   no separate skill needed.

## Output summary

End with a compact report:

- Detected stack + confidence.
- Profile applied (source: user / starter).
- Files created / merged (count only; the plan has the detail).
- Hook phases run, with any skip records.
- Whether CLAUDE.md was under the soft-cap budget.
- Next steps the user can take.

## When something goes wrong

- Detection confidence low → ask before writing.
- `preview.sh` declined → stop, no cleanup needed (nothing was written).
- Any bin script exits non-zero during execute → do not proceed; show the failing step's stderr
  and exit. The user can re-run after fixing.
- A structured skip record is *not* a failure; include it in the summary but keep going.
