---
name: release
description: >
  Cut a new release: group Conventional Commits since the last tag,
  append a CHANGELOG section, create a release commit, and add an
  annotated git tag.
  TRIGGER when the user says "cut a release", "tag a release",
  "release v1.2.0", "ship version 1.2.0", "create a release for
  1.2.0", "bump the version to 1.2.0", "make a release",
  "generate a changelog and tag", "what version should I release",
  "what's the next version", "bump minor", "bump major",
  "bump patch", "suggest a version", "/nyann:release".
  Do NOT trigger on "release branch" / "cut a release branch" — that
  is the `new-branch` skill with `--purpose release`. Do NOT trigger
  on "publish to npm" / "push to pypi" — those are package-manager
  operations outside nyann's wedge.
---

# release

Wraps `bin/release.sh`. Default strategy is `conventional-changelog`:
walk the commit range since the last matching tag, group commits by
Conventional Commits type, prepend a CHANGELOG block, commit the
changelog, then annotated-tag `v<version>`.

## 0. Drift check (quick, non-blocking)

Run `bin/session-check.sh` before starting. If it produces output,
show the one-line drift summary to the user as an informational note
(e.g. "Heads up: nyann detected drift vs your profile. Run
`/nyann:retrofit` when you get a chance."). Do not block the release
flow — this is a nudge, not a gate.

## 1. Suggest version (when not explicitly provided)

When the user does **not** supply an explicit `--version`, run
`bin/recommend-version.sh` to suggest one:

```
bin/recommend-version.sh --target <cwd> [--tag-prefix <p>]
```

Show the recommendation to the user:

> Based on commits since `<current>`, I'd suggest **`<recommended>`**
> (`<bump>` bump — `<reason>`). Shall I proceed with `<recommended>`,
> or would you prefer a different version?

Wait for confirmation before proceeding. The user can accept, override
with a different version, or abort.

When the user **does** supply an explicit version (e.g. "release v2.0.0"),
skip this step entirely — don't second-guess them.

When the user says "bump minor" / "bump major" / "bump patch", run
`recommend-version.sh` to get the current version, then apply the
requested bump type (ignore the script's own recommendation). Confirm
the computed version with the user before proceeding.

## 2. Collect inputs

- **`--version <x.y.z>`** — required for `release.sh`. Must be semver
  (or `x.y.z-prerelease`). Populated from step 1 when the user
  accepted the suggestion, or from their explicit input.
- **`--strategy`** — defaults to `conventional-changelog`. Override to
  `manual` when the user says "just tag it, skip the changelog".
  `changesets` / `release-please` are soft-skip values: the script
  emits a skip record pointing the user at those tools directly.
- **`--changelog <path>`** — defaults to `CHANGELOG.md`. Override when
  the repo uses a different file.
- **`--tag-prefix <p>`** — defaults to `v`. Override for monorepos
  that namespace tags (`api-v1.2.0`).
- **`--from <ref>`** — defaults to the latest tag matching
  `tag_prefix`. Override when the user says "include everything
  since commit X".

When the repo's active profile has a `release` block, prefer its
values over the defaults. Ask before overriding what the profile
declares.

## 3. Pre-flight

- Current tag `<prefix><version>` must not already exist. If it does,
  `release.sh` dies with a clear message; relay it.
- Working tree must be clean. Refuse on dirty tree and ask the user
  to commit or stash first. (Exception: `--dry-run` skips this
  gate so the user can preview.)
- Branch doesn't matter — release can cut from any branch (main is
  the common case, but patch releases from `release/*` or
  `hotfix/*` are legitimate).

## 4. Dry-run first if uncertain

When the user says "what would a release look like" or the commit
range is large (>20 commits), run `--dry-run` first and show the
rendered changelog block back to them. Ask for confirmation before
the real run.

## 5. Invoke

```
bin/release.sh --target <cwd> --version <x.y.z> \
  [--strategy conventional-changelog|manual] \
  [--changelog <path>] [--tag-prefix <p>] \
  [--from <ref>] [--push] [--dry-run] [--yes] \
  [--wait-for-checks] [--allow-no-pr] \
  [--wait-for-checks-timeout <sec>] \
  [--wait-for-checks-interval <sec>] \
  [--bump-manifests] [--gh-release] [--profile <path>]
```

**Preview-before-mutate:** when `--strategy conventional-changelog` and
the run is NOT `--dry-run`, `release.sh` requires `--yes`. Without it,
the script prints the rendered CHANGELOG block to stderr and exits 2
so the caller is forced to confirm before the mutation. The intended
flow is:

1. Run once with `--dry-run` → show the rendered `changelog` block back
   to the user and ask if it looks right.
2. If yes, re-run with `--yes` (same args) → actual write + commit.

Skip `--yes` handling for `--strategy manual` (no CHANGELOG write).

`--push` pushes the tag (and the release commit for
`conventional-changelog`) to `origin`. Use when the user explicitly
says "push the tag" or "publish the release". For quieter flows, skip
`--push` and let the user run `git push --follow-tags` themselves.

`--wait-for-checks` looks up the PR for HEAD via
`gh pr list --search <SHA>` and gates the tag step on that PR's CI
via `bin/wait-for-pr-checks.sh`. Use when the user says "tag the
release once CI is green" or "don't tag if CI is broken". Hard-fails
on CI failure / timeout / unreachable gh — the user opted into
gating.

When **no PR matches HEAD** (legitimate for first-cut releases or
local-only commits, but also a CI-bypass risk in squash/rebase
release flows), the default is also a hard-fail. Pass
`--allow-no-pr` alongside `--wait-for-checks` to opt in to the
proceed-without-PR path (output shows `ci_gate.outcome:"no-pr-found"`);
without it the release exits 2 and points the user at the flag.

Skipped silently on `--dry-run` so a "show me the plan" call never
burns 30 minutes polling.

### 5.1 Manifest bumps + GitHub release (`--bump-manifests`, `--gh-release`)

When the resolved profile declares `release.bump_files[]`, default the
invocation to `--bump-manifests` so manifest version strings (`plugin.json`,
`marketplace.json`, `package.json`, `pyproject.toml`, etc.) get rewritten
to `--version` and land in the same release commit as `CHANGELOG.md`.
The dry-run output's `bumped_files[]` array previews each file's
`from_version` and `action` (`bumped` vs `unchanged`); show that to the
user before the real run.

When the user says "publish the release on GitHub" / "create the GH
release too" / the active profile signals `gh-release: true`, also pass
`--gh-release`. The flag requires `--push` (the GH release attaches to
the just-pushed tag) and runs `gh release create <tag> --notes-file
<rendered-changelog>` after the push succeeds. For pre-release versions
(`-rc.N`, `-beta.N`), the script auto-passes `--prerelease` to gh.

Both flags are opt-in. On profiles WITHOUT `release.bump_files`, do not
auto-pass `--bump-manifests` — it would be a no-op but the skill should
stay quiet about flags the profile doesn't declare. On `--strategy
manual`, `--bump-manifests` is rejected up-front (no commit for the
bumps to land in).

When passing `--bump-manifests`, also pass `--profile <path>` if the
caller already has the resolved profile snapshot in hand (otherwise
`release.sh` re-resolves the default profile via `load-profile.sh`).

## 6. Interpret the output

| status | what happened |
|---|---|
| `released` | Tag created (and CHANGELOG + release commit for conventional-changelog). Report the tag name and pushed? flag. |
| `noop` | No commits since `from` ref. Nothing to release. Tell the user. |
| `skipped` | Strategy was `changesets` or `release-please` — relay the reason; point them at those tools. |

The JSON includes the rendered `changelog` block — read it back to
the user so they know what landed in CHANGELOG.md before pushing.

When `--bump-manifests` was used, the JSON includes `bumped_files[]`
with one record per declared file (`bumped` vs `unchanged`). Read this
back too — especially the `unchanged` entries, which surface as a quiet
"the file was already at the target version" rather than a silent
no-op.

When `--gh-release` was used, the JSON includes `gh_release` with one
of three outcomes: `created` (URL), `skipped` (gh missing/unauthed,
with a recovery command in `next_steps[]`), or `failed` (with the
redacted error string and a manual recovery command). The tag stays on
origin in every case — nyann never undoes a successful tag push.

## 7. Breaking changes

Commits with `!` after the type/scope (e.g. `feat(api)!: remove X`)
and commits whose body contains `BREAKING CHANGE:` are currently
detected from the subject `!` marker only (body parsing is out of
scope for v1). If the user tells you a commit without `!` is
actually a breaking change, suggest they either amend the subject or
manually edit the rendered CHANGELOG block before committing.

## When to hand off

- "Push the tag now" — use `--push`, or invoke `git push --follow-tags`
  via Bash after the fact.
- "Draft GitHub release notes" — out of scope; point the user at
  `gh release create <tag> --generate-notes` as a follow-up.
- "Revert the release" — `undo` skill for the commit;
  `git tag -d <tag>` + `git push origin :refs/tags/<tag>` for the tag
  itself. Destructive — always confirm first.
