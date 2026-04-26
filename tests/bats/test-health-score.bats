#!/usr/bin/env bats
# bin/compute-health-score.sh — health score formula and output tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPUTE="${REPO_ROOT}/bin/compute-health-score.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_drift() {
  cat > "$TMP/drift.json" <<JSON
{
  "target": "/tmp/test-repo",
  "profile": "test",
  "missing": $1,
  "misconfigured": $2,
  "non_compliant_history": { "checked": 50, "offenders": $3 },
  "documentation": {
    "claude_md": $7,
    "links": { "checked": 0, "broken": $4, "needs_mcp_verify": [], "skipped": [] },
    "orphans": { "scanned": 0, "orphans": $5 },
    "staleness": { "enabled": true, "scanned": 0, "stale": $6 },
    "subsystem_errors": $8
  },
  "summary": {}
}
JSON
}

@test "clean drift report → score 100" {
  make_drift '[]' '[]' '[]' '[]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 100 ]
}

@test "2 missing items → score 84 (100 - 2*8)" {
  make_drift '[{"kind":"a","path":"a"},{"kind":"b","path":"b"}]' '[]' '[]' '[]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 84 ]
}

@test "1 misconfigured → score 96 (100 - 4)" {
  make_drift '[]' '[{"path":"a","reason":"b"}]' '[]' '[]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 96 ]
}

@test "non-compliant history capped at -15" {
  entries='['
  for i in $(seq 1 20); do
    [[ "$i" -gt 1 ]] && entries="${entries},"
    entries="${entries}{\"sha\":\"abc${i}\",\"subject\":\"bad ${i}\"}"
  done
  entries="${entries}]"
  make_drift '[]' '[]' "$entries" '[]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 85 ]
}

@test "broken links deduction: -5 per link" {
  make_drift '[]' '[]' '[]' '[{"link":"a","reason":"b"},{"link":"c","reason":"d"}]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 90 ]
}

@test "score clamped to 0 (never negative)" {
  entries='['
  for i in $(seq 1 20); do
    [[ "$i" -gt 1 ]] && entries="${entries},"
    entries="${entries}{\"kind\":\"a\",\"path\":\"file${i}\"}"
  done
  entries="${entries}]"
  make_drift "$entries" '[]' '[]' '[]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 0 ]
}

@test "breakdown includes all deduction types" {
  make_drift '[]' '[]' '[]' '[]' '[]' '[]' '{}' '[]'
  run bash "$COMPUTE" --drift-report "$TMP/drift.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.breakdown | has("missing","misconfigured","non_compliant","broken_links","claude_md","orphans","stale","subsystem_errors")' >/dev/null
}

@test "reads from stdin when no --drift-report" {
  make_drift '[]' '[]' '[]' '[]' '[]' '[]' '{}' '[]'
  run bash -c "cat $TMP/drift.json | bash $COMPUTE"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -r '.score')
  [ "$score" -eq 100 ]
}
