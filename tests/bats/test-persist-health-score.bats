#!/usr/bin/env bats
# bin/persist-health-score.sh — score persistence, rolling window, trend.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PERSIST="${REPO_ROOT}/bin/persist-health-score.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO/memory"
}

teardown() { rm -rf "$TMP"; }

make_score() {
  cat > "$TMP/score.json" <<JSON
{ "score": $1, "breakdown": { "missing": 0, "misconfigured": 0 } }
JSON
}

@test "creates health.json on first run" {
  make_score 95
  run bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test
  [ "$status" -eq 0 ]
  [ -f "$REPO/memory/health.json" ]
  score=$(jq -r '.scores[0].score' "$REPO/memory/health.json")
  [ "$score" -eq 95 ]
}

@test "appends to existing health.json" {
  make_score 90
  bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test >/dev/null 2>&1
  make_score 85
  bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test >/dev/null 2>&1
  count=$(jq '.scores | length' "$REPO/memory/health.json")
  [ "$count" -eq 2 ]
}

@test "rolling window prunes to 90 entries" {
  # Create a health.json with 90 entries
  entries='['
  for i in $(seq 1 90); do
    [[ "$i" -gt 1 ]] && entries="${entries},"
    entries="${entries}{\"timestamp\":\"2025-01-${i}T00:00:00Z\",\"score\":80,\"profile\":\"test\",\"breakdown\":{}}"
  done
  entries="${entries}]"
  jq -n --argjson s "$entries" '{ scores: $s, trend: { direction: "stable", delta: 0, window_days: 7 } }' > "$REPO/memory/health.json"
  make_score 95
  bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test >/dev/null 2>&1
  count=$(jq '.scores | length' "$REPO/memory/health.json")
  [ "$count" -eq 90 ]
}

@test "trend computation: up when latest > avg by >2" {
  # Pre-seed with low scores
  jq -n '{ scores: [
    {"timestamp":"2025-01-01T00:00:00Z","score":70,"profile":"test","breakdown":{}},
    {"timestamp":"2025-01-02T00:00:00Z","score":72,"profile":"test","breakdown":{}},
    {"timestamp":"2025-01-03T00:00:00Z","score":71,"profile":"test","breakdown":{}}
  ], trend: { direction: "stable", delta: 0, window_days: 7 } }' > "$REPO/memory/health.json"
  make_score 90
  bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test >/dev/null 2>&1
  dir=$(jq -r '.trend.direction' "$REPO/memory/health.json")
  [ "$dir" = "up" ]
}

@test "trend computation: down when latest < avg by >2" {
  jq -n '{ scores: [
    {"timestamp":"2025-01-01T00:00:00Z","score":95,"profile":"test","breakdown":{}},
    {"timestamp":"2025-01-02T00:00:00Z","score":93,"profile":"test","breakdown":{}},
    {"timestamp":"2025-01-03T00:00:00Z","score":94,"profile":"test","breakdown":{}}
  ], trend: { direction: "stable", delta: 0, window_days: 7 } }' > "$REPO/memory/health.json"
  make_score 70
  bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test >/dev/null 2>&1
  dir=$(jq -r '.trend.direction' "$REPO/memory/health.json")
  [ "$dir" = "down" ]
}

@test "concurrent persists both retain their entries (no lost update)" {
  # Regression for the read→modify→write race: two persists running at
  # once both read the same `existing`, and without the file lock the
  # second `mv` clobbers the first writer's appended entry. With the
  # nyann::lock guard, the writes serialize and both land. Seed 1 entry,
  # fire two distinct concurrent persists, assert 3 total entries.
  jq -n '{ scores: [
    {"timestamp":"2025-01-01T00:00:00Z","score":80,"profile":"test","breakdown":{}}
  ], trend: { direction: "stable", delta: 0, window_days: 7 } }' > "$REPO/memory/health.json"

  # Distinct score files so the dedup (same ts+score) can't merge them,
  # and distinct enough scores that both produce real appends.
  cat > "$TMP/score-a.json" <<'JSON'
{ "score": 91, "breakdown": { "missing": 0, "misconfigured": 0 } }
JSON
  cat > "$TMP/score-b.json" <<'JSON'
{ "score": 73, "breakdown": { "missing": 0, "misconfigured": 0 } }
JSON

  bash "$PERSIST" --target "$REPO" --score "$TMP/score-a.json" --profile a >/dev/null 2>&1 &
  pid_a=$!
  bash "$PERSIST" --target "$REPO" --score "$TMP/score-b.json" --profile b >/dev/null 2>&1 &
  pid_b=$!
  wait "$pid_a"
  wait "$pid_b"

  count=$(jq '.scores | length' "$REPO/memory/health.json")
  [ "$count" -eq 3 ]
  # Both writers' entries survived — neither was clobbered.
  has_a=$(jq '[.scores[] | select(.score == 91)] | length' "$REPO/memory/health.json")
  has_b=$(jq '[.scores[] | select(.score == 73)] | length' "$REPO/memory/health.json")
  [ "$has_a" -eq 1 ]
  [ "$has_b" -eq 1 ]
  # The lock directory was released, not left behind.
  [ ! -e "$REPO/memory/health.json.lock" ]
}

@test "trend computation: stable when delta <=2" {
  jq -n '{ scores: [
    {"timestamp":"2025-01-01T00:00:00Z","score":90,"profile":"test","breakdown":{}},
    {"timestamp":"2025-01-02T00:00:00Z","score":91,"profile":"test","breakdown":{}}
  ], trend: { direction: "stable", delta: 0, window_days: 7 } }' > "$REPO/memory/health.json"
  make_score 91
  bash "$PERSIST" --target "$REPO" --score "$TMP/score.json" --profile test >/dev/null 2>&1
  dir=$(jq -r '.trend.direction' "$REPO/memory/health.json")
  [ "$dir" = "stable" ]
}
