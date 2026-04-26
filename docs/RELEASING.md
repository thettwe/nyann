# Releasing nyann

End-to-end checklist for cutting a release. Owner: project maintainer.

The actual mechanics live in `bin/release.sh` (and `/nyann:release`); this doc covers the GitHub-side setup that needs to be in place **before** the first tag, plus the things to verify after.

## Pre-flight (one-time, before the first tag)

These are GitHub repository-settings tasks. Do them before tagging `v1.0.0`; everything after relies on them being in place.

### 1. Tag protection

GitHub → Settings → Tags → Add a rule.

- **Pattern:** `v*`
- **Restrict tag creation/deletion to:** maintainers (org admin or specific GitHub IDs)
- **Block force-push:** ON

This is what stops a leaked PAT from rewriting `v1.0.0` to point at malicious code. The marketplace consumes the tag — if the tag can be moved, the supply chain breaks.

### 2. Branch protection on `main`

GitHub → Settings → Branches → Add rule.

- **Branch name pattern:** `main`
- **Require a pull request before merging:** ON
  - **Required approvals:** at least 1 (or self-approval if solo)
  - **Dismiss stale approvals when new commits are pushed:** ON
  - **Require review from Code Owners:** ON if you maintain a CODEOWNERS file
- **Require status checks to pass before merging:** ON
  - **Required checks:** `lint + bats` (the matrix job from `.github/workflows/ci.yml`) on both `ubuntu-latest` and `macos-latest`
  - **Require branches to be up to date before merging:** ON
- **Require conversation resolution before merging:** ON
- **Restrict who can push to matching branches:** maintainers only
- **Allow force pushes:** OFF
- **Allow deletions:** OFF

### 3. Repository security settings

GitHub → Settings → Code security and analysis. Enable everything that's free:

- **Dependency graph:** ON
- **Dependabot alerts:** ON
- **Dependabot security updates:** ON
- **Dependabot version updates:** ON — see `.github/dependabot.yml` (add one if missing). Pin both `github-actions` and any package ecosystems the project uses.
- **Secret scanning:** ON
- **Push protection (secret scanning):** ON — blocks commits that contain secrets at push time
- **Code scanning:** ON — enable CodeQL with the default config

### 4. Required identity for release commits

`bin/release.sh` calls `nyann::resolve_identity` to pick the commit author. For released commits this MUST resolve to a real identity, not the `nyann@local` fallback. Verify:

```sh
git config user.email   # must be your real address
git config user.name    # must be your real name
git config user.signingkey  # optional; required if tag.gpgsign=true
```

Set these globally (`--global`) or per-repo before running `release.sh`.

### 5. Marketplace listing alignment

Check `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` agree on:

- `version` — bump from `1.0.0-dev` to `1.0.0` in both files in the same commit
- `description` — must be identical between the two
- `keywords` — must be identical between the two
- `license` — `MIT`, matches `LICENSE`
- `repository` — points at the canonical GitHub URL

The `tests/bats/test-public-surface-counts.bats` lock asserts skill / command / profile / schema counts haven't drifted; verify it passes.

## Release ritual

Run from `main` with a clean working tree, on a checkout that is fast-forward up to `origin/main`.

```sh
# 1. Sync locally and confirm clean.
git checkout main
git pull --ff-only origin main
git status   # must be clean

# 2. Bump manifest from 1.0.0-dev to the actual version.
#    Edit both .claude-plugin/plugin.json and marketplace.json,
#    then commit and push as a normal PR.

# 3. After the manifest-bump PR merges, run release.sh:
bin/release.sh --version 1.0.0 --yes --push
```

`release.sh` will:
1. Refuse if the working tree is dirty
2. Refuse if `v1.0.0` already exists locally
3. Render the next CHANGELOG section from Conventional Commits since the last tag (or root if none)
4. Print the rendered section + diff to stderr; require `--yes` to confirm
5. Atomically prepend the section to `CHANGELOG.md`
6. Create the release commit with the configured git identity
7. Create the annotated tag `v1.0.0`
8. With `--push`: push the tag, then push the branch (each surfaces auth/network/protected-branch failures via `nyann::warn`)

If anything fails between commit and tag, see "Recovery" below.

## Post-release verification

After the tag pushes, verify:

1. **The marketplace tag resolves.** `gh api repos/thettwe/nyann/git/ref/tags/v1.0.0` returns a 200 with the expected SHA.
2. **The release commit is on `origin/main`.** `git fetch && git log origin/main --oneline | head -5` shows the `chore(release): v1.0.0` commit at the top.
3. **CI on `main` passes against the release SHA.** GitHub Actions → CI → most recent main run is green on both ubuntu and macos.
4. **The CHANGELOG link works.** Open the link from `CHANGELOG.md`'s `[1.0.0]:` reference in a browser.
5. **`/plugin install nyann@nyann` against a fresh checkout actually installs.** Ideally test in a throwaway terminal session.

## Recovery from partial-failure states

`release.sh` is best-effort about pushing — it never silently swallows a push failure, but the local tag may exist while the remote tag does not. Recovery options:

- **Tag created locally, push to `origin` failed.** Re-push manually: `git push origin v1.0.0`. If the failure was a credentials issue, fix it and re-run `git push origin v1.0.0` then `git push origin main` (the release commit also needs to ship).
- **Tag pushed, branch push failed.** `git push origin main` after fixing the cause. The tag points at a commit that's now only on the tag, not on `main` — confusing for consumers but recoverable.
- **Want to abort the release entirely.** `git tag -d v1.0.0` (delete local tag) and `git reset --hard HEAD~1` (drop the release commit). Force-push only if the broken state is already on `origin/main` AND tag protection allows it (it shouldn't — see pre-flight). If protection blocks, open a maintenance PR to revert.
- **Tag points at the wrong commit.** Don't try to "move" a published tag. Cut a new patch release (`v1.0.1`) that supersedes; mark `v1.0.0` as broken in the CHANGELOG. Tag protection prevents tag movement on purpose.

## Cadence

- **Patch (`vX.Y.Z` → `vX.Y.Z+1`):** for security fixes and bug fixes that don't change the user-visible contract. Goal: same-day for HIGH/CRITICAL security, weekly otherwise.
- **Minor (`vX.Y.0` → `vX.Y+1.0`):** for new skills, new schemas, new profile types. Roughly monthly.
- **Major (`vX.0.0` → `vX+1.0.0`):** breaking changes to skill triggers, schema rename without a parallel-reader period, or removal of starter profiles. Avoid; cite a migration plan in the CHANGELOG when unavoidable.

## Communication after release

Post a one-paragraph release note in the marketplace channel + GitHub Discussions. Link to:
- The CHANGELOG entry for the version
- Any user-action-required notes (deprecations, behaviour changes)
- The full diff: `https://github.com/thettwe/nyann/compare/<previous>...<this>`
