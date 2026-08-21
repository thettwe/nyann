---
name: fleet-retrofit
description: >
  Bulk remediation across the fleet registry: fix drift repo-by-repo and
  optionally bootstrap the un-governed ones — every repo previewed and
  confirmed individually. TRIGGER when the user says "fix drift across all
  my repos", "retrofit the fleet", "retrofit all my repos", "bring every
  repo into compliance", "remediate my whole fleet", "bootstrap all my
  repos", "set up nyann on every repo", "clean up governance across my
  repos", "/nyann:fleet-retrofit".
  Do NOT trigger on single-repo remediation ("fix this repo's drift") —
  that's `retrofit` — or single-repo setup — that's `bootstrap-project`.
  Do NOT trigger on "show fleet health" / "which repos are drifting" —
  that's `fleet` (read-only).
---

# fleet-retrofit

> **Plugin root:** `<plugin_root>/skills/fleet-retrofit/SKILL.md` — the
> planning/bookkeeping engine is `<plugin_root>/bin/fleet-retrofit.sh`;
> per-repo mutation reuses the SAME scripts the single-repo flows use.

**The safety contract (non-negotiable):** every mutation happens through
the per-repo preview-and-confirm chain — plan → `preview.sh` → an
AskUserQuestion for THAT repo → SHA-bound `bootstrap.sh`. There is no
"yes to all": a fleet-wide approval would skip previews, which nyann never
does. Each repo writes its own BootRecord, so any repo is individually
reversible via `/nyann:undo-bootstrap`. In a non-interactive context
(`NYANN_NONINTERACTIVE=true` / CI), stop after the plan and report — bulk
mutation without a human cannot happen, by construction.

## 1. Plan

```
run_file=$(mktemp -t nyann-fleet-run.XXXXXX)
bin/fleet-retrofit.sh --plan [--bootstrap-missing] [--tag t] [--only a,b] \
                      --run-file "$run_file"
```

The plan classifies every registry entry — `clean`, `drifted` (report-only
drift computation), `ungoverned` (no boot record and no resolvable
profile), or `error` — read-only, one broken repo never aborts it.
Exit 0 means nothing to do: report "fleet is clean" and stop.

Include `--bootstrap-missing` only when the user asked to set up new repos
too ("bootstrap all my repos", "including the ones nyann never touched").
If they didn't say and the plan shows `ungoverned` repos being skipped,
mention the count and ask once whether to re-plan with the flag.

## 2. Confirm the scope

Show the plan summary (drifted / ungoverned / clean / error counts and the
worst repos) and confirm with ONE AskUserQuestion that the user wants to
walk the fleet. Offer "stop here" — the plan alone is a useful artifact.

## 3. Walk the repos (plan order — worst first)

For each `pending` repo, work **inside that repo's path** (every `--target`
below is the fleet entry's path, and the profile is the plan row's
`profile`):

- **`drifted` →** follow the remediation flow in
  `skills/retrofit/SKILL.md` §5 verbatim (ActionPlan from the drift report
  → `route-docs.sh` → `render-plan.sh` → `preview.sh` → confirm →
  `bootstrap.sh --plan-sha256 <sha> --source retrofit`). Do not re-derive
  it here — the single-repo skill is the source of truth.
- **`ungoverned` (only with `--bootstrap-missing`) →** follow
  `skills/bootstrap-project/SKILL.md` for that path: `suggest-profile.sh`
  picks the profile (confirm the pick when confidence is low), then the
  standard detect → plan → preview → confirm → `bootstrap.sh` chain.

Per repo, the AskUserQuestion offers: **apply** / **skip this repo** /
**stop the run**. Record the outcome immediately after each repo:

```
bin/fleet-retrofit.sh --record --run-file "$run_file" --repo <path> \
  --action retrofitted|bootstrapped|declined|skipped|failed \
  [--exit-code <n>] [--detail "<one line>"]
```

A failed repo is recorded `failed` and the walk continues — failure
isolation is the point of the run file.

## 4. Finalize + report

```
bin/fleet-retrofit.sh --finalize --run-file "$run_file"
```

Unreached repos become `skipped`; the summary counts fill in. Render the
final table (retrofitted / bootstrapped / declined / skipped / failed per
repo) and close with:

- **Verify:** offer `/nyann:fleet` (fleet-doctor) to confirm the drift is
  gone — before/after fleet scores make the run's value visible.
- **Undo:** any repo can be individually reverted:
  "`/nyann:undo-bootstrap` inside <path>".
- Pinned-profile hygiene: repos remediated against a `fallback` profile
  should get a pin (`bin/fleet.sh --add <path> --profile <p>`) so the next
  run doesn't guess.

## What this skill does NOT do

- No history rewrites, no pushes, no PRs — same limits as single-repo
  retrofit.
- No mutation outside the per-repo confirm. Declining a repo records
  `declined` and moves on; it is never re-asked in the same run.
