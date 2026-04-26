# Conventional Commits reference

Authoritative reference for the `commit` skill. Load this file before
generating any commit message.

## Grammar

```
<type>[(<scope>)][!]: <description>

[optional body]

[optional footer(s)]
```

## Types

| Type | Use when |
|---|---|
| `feat` | A new user-facing feature. Bumps MINOR on semver. |
| `fix` | A bug fix. Bumps PATCH. |
| `docs` | Documentation-only changes (README, comments, docs/). |
| `refactor` | Code change that neither fixes a bug nor adds a feature. |
| `test` | Adding or adjusting tests. |
| `chore` | Build/tooling changes that aren't user-facing (lockfile bumps, meta). |
| `perf` | Performance-improving change. |
| `ci` | CI/CD configuration only. |
| `build` | Build-system changes (webpack config, package.json scripts). |
| `style` | Whitespace, semicolons, formatting (no code logic change). |
| `revert` | Reverts a prior commit. Body names the reverted SHA. |

Rule: nyann's installed commit-msg regex is
`^(feat|fix|chore|docs|refactor|test|perf|ci|build|style|revert)(\([^)]+\))?!?: .+`
— stay inside this set.

## Scope

Optional. A noun naming the subsystem, package, or feature area:

- `feat(api): add /healthz endpoint`
- `fix(ui): checkout button disabled on mobile`
- `chore(deps): bump next to 15.0.4`

Infer scope from touched paths. Don't invent a scope if one file spans
concerns — leave scope off rather than guess.

If the profile declares `conventions.commit_scopes`, prefer those. Fall
back to the first meaningful path segment otherwise (e.g. `src/api/...`
→ `api`; `apps/web/...` → `web`).

## Breaking changes

Two forms, both valid. Use the `!` only when a public API really breaks:

1. Short form (most common):
   ```
   feat(api)!: drop v1 /auth endpoint

   BREAKING CHANGE: clients must migrate to /v2/auth.
   ```

2. Footer-only form (use when the change is buried in a refactor):
   ```
   refactor(auth): split session middleware

   BREAKING CHANGE: removes the `req.userId` shim; use req.user.id.
   ```

The `BREAKING CHANGE:` footer is mandatory when `!` is present. Reverse
is NOT true — you can have a footer without `!` (footer-only form).

## Description

- Imperative mood: "add", "fix", "drop" — not "added", "fixed", "drops".
- No trailing period.
- ≤ 72 characters.
- Lowercase after the colon unless the term is a proper noun.

Bad: `fix: Fixed a bug where the button was broken.`
Good: `fix(ui): disable checkout button until form validates`

## Body

Optional but encouraged when the subject isn't self-explanatory.

- One blank line between subject and body.
- Wrap at 72 chars.
- Answer "why" more than "what" (the diff already shows what).
- Multiple paragraphs allowed; separate with blank lines.

## Footers

Format: `Token: value` (or `Token #N`). Common tokens:

- `Closes #123` — closes an issue on merge (GitHub).
- `Fixes #123` — same intent; alternative wording.
- `Refs #123` — references without closing.
- `Co-authored-by: Name <email>` — co-author credit (GitHub multi-author).
- `BREAKING CHANGE: ...` — mandatory with `!`; describes the break.

Never put `Closes #N` in the subject line; it belongs in a footer block.

## Multi-file diffs

- Pick the dominant change. If 8 files change and 7 of them are a refactor
  with 1 new feature, the subject is `refactor(...)` and the body mentions
  the new feature.
- If the commit genuinely mixes types (feat + fix + chore), tell the user
  it should be split. Don't write a "misc" commit.

## Examples (from diverse diffs)

```
feat: add login page
feat(api): add /healthz endpoint
fix(ui): disable submit until form validates
fix: handle 204 as success in response parser
docs: explain the retry policy in architecture.md
refactor(auth): extract token parser into its own module
test(cli): add coverage for --dry-run path
chore(deps): bump prettier to 3.3
perf(search): precompute ngram index on startup
ci: fail build when coverage dips below 80%

feat(cli)!: rename --flag to --option

BREAKING CHANGE: scripts calling --flag must update to --option.

fix(parser): handle trailing commas in JSON5 inputs

Previously we crashed on inputs like `{a: 1,}`. The upstream JSON5
library accepts these; we mirror that behavior so piped tooling works.

Closes #412
```

## When NOT to use `!`

A common generator mistake. `!` only applies to **public** API breaks
that downstream users must react to. Internal refactors that change
function signatures *within the same module* are not breaking.

Examples:

- Renaming an exported public function → `!`.
- Changing CLI flag semantics → `!`.
- Renaming a private helper → NO `!` (just `refactor`).
- Dropping a dev dependency → NO `!` (just `chore(deps)`).
