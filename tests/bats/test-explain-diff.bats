#!/usr/bin/env bats
# bin/explain-diff.sh — DriftReport → markdown / DriftNarrative JSON.
#
# Inline fixtures rather than golden files: keeps the test self-
# contained and makes severity-mapping regressions obvious in the diff
# (the expected substrings live next to the JSON that produces them).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  EXPLAIN="${REPO_ROOT}/bin/explain-diff.sh"
  SCHEMA="${REPO_ROOT}/schemas/drift-narrative.schema.json"
  TMP=$(mktemp -d)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Helper: emit a "rich" DriftReport that exercises every severity tier.
write_rich_drift() {
  cat > "$TMP/drift.json" <<'EOF'
{
  "target": "/repo/example",
  "profile": "node-api",
  "scope_applied": ["docs","hooks","branching","gitignore","editorconfig","github","history"],
  "missing": [
    {"kind": "hook",   "path": ".husky/pre-commit", "detail": "profile expects gitleaks hook"},
    {"kind": "config", "path": ".editorconfig"}
  ],
  "misconfigured": [
    {"path": ".gitignore", "reason": "missing standard Node.js ignores", "missing_entries": ["node_modules/", ".env"]}
  ],
  "misplaced": [
    {"source": "ARCHITECTURE.md", "target": "docs/architecture.md", "category": "architecture", "confidence": 0.95}
  ],
  "non_compliant_history": {
    "checked": 50,
    "offenders": [
      {"sha": "abc1234", "subject": "fix the thing"}
    ]
  },
  "documentation": {
    "claude_md": {"status": "warn", "bytes": 4096, "budget_bytes": 3072, "hard_cap_bytes": 8192},
    "links": {"checked": 12, "broken": [{"source": "docs/foo.md", "link": "missing.md"}], "needs_mcp_verify": [], "skipped": []},
    "orphans": {"scanned": 5, "orphans": [{"path": "docs/old.md", "last_modified_days_ago": 200}]},
    "staleness": {"enabled": true, "threshold_days": 90, "scanned": 5, "stale": [{"path": "docs/runbook.md", "last_modified_days_ago": 120}]}
  },
  "summary": {
    "missing": 2, "misconfigured": 1, "misplaced": 1, "non_compliant_commits": 1,
    "broken_links": 1, "orphans": 1, "stale_docs": 1, "claude_md_status": "warn"
  }
}
EOF
}

# Helper: a clean DriftReport (no findings).
write_clean_drift() {
  cat > "$TMP/drift.json" <<'EOF'
{
  "target": "/repo/clean",
  "profile": "default",
  "missing": [],
  "misconfigured": [],
  "non_compliant_history": {"checked": 5, "offenders": []},
  "documentation": {
    "claude_md": {"status": "ok", "bytes": 1024, "budget_bytes": 3072},
    "links": {"checked": 3, "broken": [], "needs_mcp_verify": [], "skipped": []},
    "orphans": {"scanned": 2, "orphans": []},
    "staleness": {"enabled": false, "scanned": 0, "stale": []}
  },
  "summary": {"missing": 0, "misconfigured": 0, "non_compliant_commits": 0, "broken_links": 0, "orphans": 0, "stale_docs": 0, "claude_md_status": "ok"}
}
EOF
}

# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------

@test "markdown render: rich report covers every severity tier" {
  write_rich_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json"
  [ "$status" -eq 0 ]
  # Header has target + profile.
  echo "$output" | grep -qF "/repo/example"
  echo "$output" | grep -qF "node-api"
  # Each lead phrase from the severity → phrase mapping fires once.
  echo "$output" | grep -qF "Action required:"
  echo "$output" | grep -qF "Worth fixing:"
  echo "$output" | grep -qF "Drifted:"
  echo "$output" | grep -qF "Minor:"
  # Per-finding lines are emitted (bullet indent).
  echo "$output" | grep -qF "  - Missing: .husky/pre-commit"
  echo "$output" | grep -qF "  - Broken link: docs/foo.md → missing.md"
  # Action-items section appears with retrofit + optimize prompts.
  echo "$output" | grep -qF "## What you can do"
  echo "$output" | grep -qF "nyann:retrofit"
  echo "$output" | grep -qF "nyann:optimize-claudemd"
}

@test "markdown render: clean report says nothing drifted" {
  write_clean_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "_No drift detected"
  # No "What's drifted" section header on a clean report.
  ! echo "$output" | grep -qF "## What's drifted"
}

@test "markdown render: health + trend embed into header on regression" {
  write_rich_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --with-health 72 --with-trend -8
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "Health score:.*72.*100"
  echo "$output" | grep -qF "regression"
  echo "$output" | grep -qF "↓ 8"
}

@test "markdown render: health-only (no trend) renders score line without arrows" {
  write_rich_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --with-health 95
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "Health score:.*95.*100"
  # No trend symbols when --with-trend is omitted.
  ! echo "$output" | grep -qE "↓|↑|→ stable"
}

# ---------------------------------------------------------------------------
# JSON rendering (DriftNarrative schema)
# ---------------------------------------------------------------------------

@test "json render: rich report validates against drift-narrative schema" {
  write_rich_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --format json \
    --with-health 72 --with-trend -8
  [ "$status" -eq 0 ]
  # jq-parse smoke test.
  echo "$output" | jq -e '
    .target == "/repo/example"
    and .profile == "node-api"
    and .health.score == 72
    and .health.trend_delta == -8
    and .health.trend_direction == "down"
    and (.sections | length) > 0
    and (.action_items | length) > 0
  ' >/dev/null

  # Full-schema validation if uvx + check-jsonschema are available
  # (the same CI dependency the rest of the suite uses).
  if command -v uvx >/dev/null 2>&1; then
    echo "$output" > "$TMP/narr.json"
    uvx check-jsonschema --schemafile "$SCHEMA" "$TMP/narr.json"
  fi
}

@test "json render: severity tiers map correctly to sections" {
  write_rich_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --format json
  [ "$status" -eq 0 ]
  # Each tier should appear at least once given the rich fixture.
  echo "$output" | jq -e '[.sections[].severity] | sort | unique' \
    | grep -qF "critical"
  echo "$output" | jq -e '
    ([.sections[].severity] | contains(["critical"]))
    and ([.sections[].severity] | contains(["high"]))
    and ([.sections[].severity] | contains(["medium"]))
    and ([.sections[].severity] | contains(["low"]))' >/dev/null
}

@test "json render: clean report yields zero sections + zero actions" {
  write_clean_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --format json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    (.sections | length) == 0
    and (.action_items | length) == 0
    and .health.score == null
  ' >/dev/null
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

@test "reads from stdin when --file -" {
  write_rich_drift
  run bash -c "cat '$TMP/drift.json' | bash '$EXPLAIN' -"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "node-api"
}

@test "rejects non-DriftReport input with a clear error" {
  echo '{"unrelated":"shape"}' > "$TMP/bad.json"
  run bash "$EXPLAIN" --file "$TMP/bad.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "not a DriftReport"
}

@test "rejects out-of-range --with-health" {
  write_clean_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --with-health 150
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "0..100"
}

@test "rejects non-integer --with-trend" {
  write_clean_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --with-trend abc
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "signed integer"
}

@test "rejects unknown --format value" {
  write_clean_drift
  run bash "$EXPLAIN" --file "$TMP/drift.json" --format yaml
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "markdown"
}
