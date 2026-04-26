---
name: nyann:release
description: >
  Cut a release: generate a CHANGELOG section from Conventional Commits,
  make a release commit, and create an annotated tag. Defaults to
  conventional-changelog strategy.
arguments:
  - name: version
    description: Semver for the release (e.g. `1.2.0` or `1.2.0-rc.1`). Required.
    optional: false
  - name: strategy
    description: One of `conventional-changelog` (default) or `manual` (tag only). `changesets`/`release-please` soft-skip.
    optional: true
  - name: push
    description: Push the tag (and release commit) to `origin` after creating.
    optional: true
  - name: dry-run
    description: Render what would happen without mutating.
    optional: true
  - name: wait-for-checks
    description: Block tag creation on green CI for HEAD's PR (resolved via `gh pr list --search <SHA>`). Hard-fails on CI fail / timeout / unreachable gh / no-PR-found. Skipped silently on `--dry-run`.
    optional: true
  - name: allow-no-pr
    description: When `--wait-for-checks` is set AND no PR matches HEAD, proceed anyway (legitimate for first-cut releases or local-only commits). Without this flag, no-PR-found is a hard error to avoid silent CI bypass on squash/rebase release flows.
    optional: true
---

# /nyann:release

Wraps `bin/release.sh`. Flow for `conventional-changelog`:

1. Find latest tag matching `tag_prefix` (default `v`). Walk commits since.
2. Group commits by Conventional Commits type. Breaking-changes (subject `!`) render first.
3. Prepend the block to CHANGELOG.md (creating the file with a header if missing).
4. Release commit: `chore(release): v<version>`.
5. Annotated tag `v<version>`.
6. Optional `--push` sends tag + commit to `origin`.

Profiles may declare an optional `release` block (strategy, changelog_path, tag_prefix) — the skill honors it when present.

`--wait-for-checks` is the safety net for "don't tag a broken build": it looks up the PR for HEAD and blocks on `bin/wait-for-pr-checks.sh` until CI passes. Output gains `ci_gate: { outcome, pr_number? }` on success so consumers can prove the gate ran. When no PR matches HEAD, the default is to fail rather than silently proceed — pass `--allow-no-pr` for first-cut or local-only releases.

See `skills/release/SKILL.md` for full flow, dry-run guidance, and breaking-change handling.
