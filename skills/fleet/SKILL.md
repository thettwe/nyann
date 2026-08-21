---
name: fleet
description: >
  Manage the fleet registry of local repos and show the cross-repo health
  dashboard (read-only). TRIGGER when the user says "show my fleet",
  "fleet dashboard", "health across all my repos", "org health view",
  "how are all my repos doing", "which of my repos are drifting",
  "audit all my repos", "run doctor on every repo", "add this repo to my
  fleet", "register my repos", "scan ~/Works for repos", "list my fleet",
  "remove <repo> from my fleet", "/nyann:fleet".
  Do NOT trigger on "watch all my repos" / "watch my PRs across repos" —
  that's `watch` (CI sentinel: remote PR/check state, not governance).
  Do NOT trigger on "fix drift across all my repos" / "retrofit the
  fleet" — that's `fleet-retrofit` (this skill never mutates a repo).
  Do NOT trigger on single-repo health ("is this repo healthy") — that's
  `doctor`.
---

# fleet

> **Plugin root:** `<plugin_root>/skills/fleet/SKILL.md` — scripts live at
> `<plugin_root>/bin/fleet.sh` (registry CRUD) and
> `<plugin_root>/bin/fleet-doctor.sh` (bulk audit + dashboard).

Read-only across the board: the registry file is the only thing this skill
ever writes, and every registry mutation previews first. The registry lives
at `~/.claude/nyann/fleet.json` and holds LOCAL working-copy paths — it is
deliberately distinct from the sentinel watch-list (GitHub slugs for remote
CI polling); an entry's optional `repo` slug is the join key between the two.

## 1. Registry management

All CRUD goes through `bin/fleet.sh` (`--fleet-file` only in tests):

| User intent | Invocation |
|---|---|
| "add this repo" | `bin/fleet.sh --add <path> [--name n] [--repo o/r] [--profile p] [--tag t]` |
| "add and watch its PRs too" | append `--watch` (mirrors the slug into the sentinel watch-list; resolves the slug from the origin remote when `--repo` is omitted) |
| "remove X" | `bin/fleet.sh --remove <name-or-path>` |
| "list my fleet" | `bin/fleet.sh --list` (JSON — render it as a table) |
| "scan ~/Works for repos" | `bin/fleet.sh --scan <dir> [--depth n]` |
| "clean out dead entries" | `bin/fleet.sh --prune` |
| "what org repos am I missing?" | `bin/fleet.sh --suggest-org <org>` (gh best-effort, advisory only — nyann never clones) |

**`--scan` and `--prune` are preview-first**: the bare call prints the
candidate list and writes NOTHING. Show the list, confirm with
AskUserQuestion, then re-run with `--apply`. Never jump straight to
`--apply`.

Add validation to expect: the path must be a git repo (it is canonicalised
to the toplevel, so re-adding a subdir dedupes); a name colliding with a
different repo's name is refused — pass a distinct `--name`.

## 2. The health dashboard

```
bin/fleet-doctor.sh [--json | --markdown] [--cached] [--drift | --explain]
                    [--tag t] [--only a,b] [--jobs n] [--timeout s]
                    [--persist] [--stale-days n] [--threshold n]
```

Default is a **live** run — each repo gets a full `doctor.sh --json` pass,
so warn the user up front that a large fleet takes a while ("~15 repos ≈ a
few minutes"); progress logs stream per repo. Offer `--jobs 4` for speed
(safe: doctor is read-only, per-repo output is merged after).

- **"quick look" / "don't re-audit, just show me"** → `--cached`: reads
  each repo's persisted `memory/health.json` instantly. The board is
  labeled `cached` and rows older than `--stale-days` (default 7) are
  flagged — present it as a snapshot, never as current truth.
- **"post this to the team channel" / "give me markdown"** → `--markdown`.
- **"record the scores"** → `--persist` (each repo's own trend series).
- Filters: `--tag backend`, `--only api,web`.

Exit codes are worst-of across the fleet, mirroring doctor: 0 clean, 4 any
warn/stale/missing/error, 5 any critical.

Reading the board for the user:

- Sorted worst-first; lead your summary with the worst repos and the fleet
  header stats (avg / min / below-threshold / critical).
- `default?` in the PROFILE column means the repo was audited against the
  `default` profile because nothing better resolved (`profile_source:
  "fallback"`). **After the run**, offer once (one AskUserQuestion, not
  per repo) to pin profiles for those repos via
  `bin/fleet.sh --add <path> --profile <p>`.
- Scores are profile-relative — an 85 under `default` is not an 85 under a
  strict team profile. Don't rank repos across different profiles as if
  equivalent; the profile column is there for exactly this reason.
- `ERROR` rows never abort the run; surface the reason (dead path → offer
  `--prune`, timeout → offer `--timeout 300`).

## 3. Drift roll-up

When the user wants the actual findings, not just counts ("what exactly is
drifting?"):

- `--drift` — appends repo-tagged findings per drifted repo and (in
  `--json`) embeds each drifted repo's full doctor report under
  `repos[].drift_report`. Live mode only — the script refuses
  `--drift --cached`.
- `--explain` — plain-English narrative per drifted repo via explain-diff
  (implies `--drift`).

## 4. What to do after

- **"fix them" / "retrofit the fleet"** → hand off to `fleet-retrofit`.
  Never remediate from inside this skill.
- **Single repo deep-dive** → `doctor` against that repo.
- **"watch these repos' PRs"** → `watch` (`--add` per repo slug, or
  re-add fleet entries with `--watch`).
