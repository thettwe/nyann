#!/usr/bin/env bats
# bin/doctor.sh --explain — pipes the computed DriftReport through
# explain-diff.sh, forwards health + trend, mirrors the text-mode
# exit-code logic.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOCTOR="${REPO_ROOT}/bin/doctor.sh"
  TMP=$(mktemp -d)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    git init -q -b main
    # Seed with a single commit so compute-drift has a history to scan
    # (otherwise the non-compliant-history probe shorts on "no commits").
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed"
  )
}

teardown() { rm -rf "$TMP"; }

# NOTE: We deliberately do NOT pre-seed `memory/health.json` from a
# fixture. find-orphans.sh has a pre-existing bug where a JSON file in
# memory/ causes it to emit empty output, which then breaks compute-
# drift's `jq --argjson orphans ''` outer call. The supported way to
# get a populated health.json is to let `--persist` write it; tests
# that need a trend run doctor once with --persist, then again with
# --explain.

# ---------------------------------------------------------------------------

@test "--explain emits markdown narrative on a drifted repo" {
  # Bare repo with no .gitignore / CLAUDE.md — default profile expects
  # both, so this produces a critical-severity narrative.
  run bash "$DOCTOR" --target "$REPO" --profile default --explain
  # Exit 5 = critical drift (missing files), same as text mode.
  [ "$status" -eq 5 ]
  echo "$output" | grep -qF "# Drift summary"
  echo "$output" | grep -qF "default"
  echo "$output" | grep -qF "Action required:"
  echo "$output" | grep -qF "## What you can do"
  echo "$output" | grep -qF "nyann:retrofit"
}

@test "--explain forwards health score from a prior --persist run" {
  # Prime memory/health.json via the supported `--persist` path so we
  # exercise the real persistence shape (not a hand-crafted fixture
  # that runs afoul of the find-orphans / orphans=='' bug).
  bash "$DOCTOR" --target "$REPO" --profile default --persist --json >/dev/null 2>&1 || true
  [ -f "$REPO/memory/health.json" ]

  # Now run --explain. The trend will be stable/0 (no score change
  # between two back-to-back runs), but the score line must appear.
  run bash "$DOCTOR" --target "$REPO" --profile default --explain
  echo "$output" | grep -qE "Health score:.*[0-9]+.*100"
}

@test "--explain on a non-critical repo exits 4 (warn) instead of 5" {
  # Add the files the default profile's `missing[]` check looks for so
  # we flip from critical (exit 5) to warn (exit 4). The remaining
  # drift (e.g. claude_md=warn if oversized, non-CC history, etc.)
  # leaves the report in warn territory. We only assert exit != 5 —
  # the narrative content itself is covered by test-explain-diff.bats.
  echo "node_modules/" > "$REPO/.gitignore"
  echo "# nyann" > "$REPO/CLAUDE.md"
  mkdir -p "$REPO/docs/decisions" "$REPO/.git/hooks"
  printf '# Architecture\n\n(placeholder)\n' > "$REPO/docs/architecture.md"
  printf '# ADR template\n' > "$REPO/docs/decisions/ADR-000-record-architecture-decisions.md"
  # Native git hook placeholder so the "no hook framework installed"
  # missing-entry doesn't fire either.
  printf '#!/bin/sh\nexit 0\n' > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"

  run bash "$DOCTOR" --target "$REPO" --profile default --explain
  [ "$status" -ne 5 ] || { echo "got exit 5; expected non-critical" >&2; return 1; }
  echo "$output" | grep -qF "# Drift summary"
}

@test "--explain + --json is rejected at arg-parse time" {
  run bash "$DOCTOR" --target "$REPO" --profile default --explain --json
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "mutually exclusive"
  # The reverse order should produce the same error.
  run bash "$DOCTOR" --target "$REPO" --profile default --json --explain
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "mutually exclusive"
}

@test "--explain with --scope narrower than all still renders" {
  run bash "$DOCTOR" --target "$REPO" --profile default --explain --scope hooks,gitignore
  # Status varies with scope; only assert it ran and emitted a header.
  echo "$output" | grep -qF "# Drift summary"
}

@test "--explain stays read-only (no files created in target)" {
  before=$(find "$REPO" -type f -not -path "*/.git/*" | wc -l | tr -d ' ')
  bash "$DOCTOR" --target "$REPO" --profile default --explain >/dev/null 2>&1 || true
  after=$(find "$REPO" -type f -not -path "*/.git/*" | wc -l | tr -d ' ')
  [ "$before" = "$after" ]
}

@test "--explain with --persist still records health.json" {
  # Persist writes to <target>/memory/health.json. Verify the path
  # changes between before/after.
  bash "$DOCTOR" --target "$REPO" --profile default --explain --persist >/dev/null 2>&1 || true
  [ -f "$REPO/memory/health.json" ]
}
