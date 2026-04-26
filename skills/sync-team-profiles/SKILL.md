---
name: sync-team-profiles
description: >
  Fetch (or refresh) registered team-profile sources — git clone on
  first run, shallow git fetch + reset on subsequent runs — and
  register discovered profiles under a namespace.
  TRIGGER when the user says "sync team profiles", "pull the latest
  team profiles", "refresh team profiles", "update team profiles",
  "sync from <team-name> profile source", "fetch profiles from the
  team repo", "/nyann:sync-team-profiles".
  Do NOT trigger on "add a new team profile source" (that's
  `add-team-source` — registers without pulling). Do NOT trigger on
  "sync my branch" (that's the `sync` skill — feature-branch
  rebase/merge). Do NOT trigger on "install a profile" from a URL
  when no source is registered yet — walk the user through
  `add-team-source` first.
---

# sync-team-profiles

Wraps `bin/sync-team-profiles.sh`.
On first run it shallow-clones each registered team-profile source
(`git clone --depth=1`); on subsequent runs it does a shallow fetch
(`git fetch --depth=1`) and `git reset --hard FETCH_HEAD` to advance
to the latest commit. Every profile under the cache is then validated
against `profiles/_schema.json`, and valid profiles are registered
under `<source-name>/<profile-name>`.

## 1. Pre-flight

- Config at `~/.claude/nyann/config.json` must have at least one
  entry in `team_profile_sources[]`. If empty, route to
  `add-team-source` first.
- Uses the sync interval from each source. When the user says
  "force refresh" / "ignore the interval" / "pull now", pass
  `--force`.
- When the user names a specific source ("sync just the platform-
  team profiles"), pass `--name <source>` so unrelated sources
  don't get pulled.

## 2. Invoke

```
bin/sync-team-profiles.sh \
  [--user-root <dir>] \
  [--force] \
  [--name <source>]
```

Network operation. Expect up to a few seconds per source. The
backend is resilient — a failing source logs the error and moves
on to the next.

## 3. Interpret the JSON summary

Top-level shape is four arrays (see `schemas/team-sync-result.schema.json`):

- `synced[]` — sources that pulled this run. Each entry: `{name, synced_at}`.
- `skipped[]` — sources within their interval window. Each entry:
  `{name, reason: "within-interval", next_due}`. Tell the user the
  next-due timestamp; they can re-run with `--force` if they need
  to pull immediately.
- `registered[]` — every profile that passed schema validation.
  Each entry: `{source, name, namespaced, path}`. The `namespaced`
  field is what to use with `bootstrap-project --profile <namespaced>`.
- `invalid[]` — anything that didn't make it through (fetch
  failure, clone failure, hand-edited config with a bad ref/url,
  TOCTOU on the cache dir, profile that fails schema validation).
  Each entry: `{name|source, kind, error}` where `kind` is one of
  `invalid-name`, `invalid-ref`, `invalid-url`, `fetch-failed`,
  `clone-failed`, `toctou`, `invalid-schema`. Show these but don't
  treat any single one as fatal — the script logs and moves on to
  the next source.

## 4. After sync

- Tell the user how many profiles are newly available.
- Suggest `inspect-profile <source>/<name>` to see what a specific
  team profile does.
- Suggest `bootstrap-project --profile <source>/<name>` to apply
  one to a repo.

## 5. When a source errors

- `git clone` / `git fetch` failures are usually auth or network
  issues and surface in `invalid[]` with `kind: clone-failed` or
  `fetch-failed`. The error string passes through `nyann::redact_url`
  before reaching the JSON, so any embedded `https://<token>@host`
  credentials are scrubbed — safe to relay verbatim. Don't try to
  auth-fix on the user's behalf.
- Corrupted cache (`<user-root>/cache/<source>/` contains partial
  data) — safe to delete the cache dir and re-run. Confirm before
  deleting; it's a file-system mutation.

## When to hand off

- "Add a new source" → `add-team-source`.
- "My team profile collides with a starter profile" — by design,
  user + team profiles can shadow starters. Clarify which version
  will win (user > team > starter) and let the user decide if the
  shadow is intentional.
- "Drift detection: is my cached team profile out of sync with the
  remote?" → that's `check-team-drift` (separate backend; not in
  this skill's scope).
