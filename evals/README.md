# Evals

Two kinds of check live here.

## Tier 1 — trigger cases

Did the skill fire on a user prompt that *should* trigger it, and stay silent on one that
shouldn't? Declared as `trigger_cases[]` in each `*.evals.json`:

```json
{ "prompt": "set me up from scratch", "should_trigger": true }
```

Running these requires a live LLM deciding whether to route a prompt to the skill. That's
out of scope for `run.sh`; the JSON is an authored spec that Anthropic's evals tooling (or a
future nightly harness) can consume.

## Tier 2 — output-quality scenarios

If the skill *does* fire on a given fixture, do the resulting artifacts satisfy every
assertion? Declared as `output_quality_scenarios[]`:

```json
{
  "name": "empty-dir-nextjs",
  "fixture": "tests/fixtures/jsts-empty",
  "profile": "nextjs-prototype",
  "assertions": [
    { "kind": "file_exists",    "path": ".husky/pre-commit" },
    { "kind": "file_contains",  "path": ".husky/pre-commit", "substring": "lint-staged" },
    { "kind": "file_size_max",  "path": "CLAUDE.md",        "bytes": 3072 }
  ]
}
```

Scenarios run deterministically via `evals/run.sh` — the harness seeds the fixture into a
throwaway temp dir, runs `bin/bootstrap.sh` end-to-end, then walks assertions. No live
Claude Code required; that's exactly the point.

## Running

```sh
./evals/run.sh                                         # all scenarios, default eval file
./evals/run.sh --file evals/bootstrap-project.evals.json
./evals/run.sh --list                                  # inspect without executing
```

Exit 0 = all scenarios pass; exit 1 = one or more failed (details on stderr).

## Adding evals

- **New trigger case:** append to `trigger_cases[]` with a tag describing the intent cluster
  (`setup-intent`, `audit-intent`, `profile-intent`, or a distractor tag).
- **New scenario:** append to `output_quality_scenarios[]` with a `name`, a fixture under
  `tests/fixtures/`, and assertions. Kinds currently supported: `file_exists`, `file_contains`,
  `file_size_max`. Add more kinds to `evals/run.sh` when a scenario needs them.
- Every reported trigger-quality bug becomes a new trigger case before the fix lands.

## Why this isn't gated on PRs

Evals are noisier than bats tests because they depend on model behavior. They are designed to run
nightly and surface regressions as issues, not as merge blockers.
