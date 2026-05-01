#!/usr/bin/env bats
# bin/health-trend.sh — health score trend report tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TREND="${REPO_ROOT}/bin/health-trend.sh"
  TMP=$(mktemp -d)

  REPO="$TMP/repo"
  mkdir -p "$REPO/memory"
}

teardown() { rm -rf "$TMP"; }

make_health() {
  local file="$REPO/memory/health.json"
  cat > "$file" <<'JSON'
{
  "scores": [
    {"timestamp":"2026-04-25T10:00:00Z","score":60,"profile":"default","breakdown":{"missing":-20,"misconfigured":-8,"non_compliant":-12}},
    {"timestamp":"2026-04-26T10:00:00Z","score":65,"profile":"default","breakdown":{"missing":-15,"misconfigured":-8,"non_compliant":-12}},
    {"timestamp":"2026-04-27T10:00:00Z","score":70,"profile":"default","breakdown":{"missing":-15,"misconfigured":-4,"non_compliant":-11}},
    {"timestamp":"2026-04-28T10:00:00Z","score":75,"profile":"default","breakdown":{"missing":-10,"misconfigured":-4,"non_compliant":-11}},
    {"timestamp":"2026-04-29T10:00:00Z","score":80,"profile":"default","breakdown":{"missing":-10,"misconfigured":-4,"non_compliant":-6}}
  ],
  "trend": {"direction":"up","delta":5,"window_days":7}
}
JSON
}

# --- basic functionality ---

@test "produces valid JSON output" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  jq -e . "$TMP/out.json" >/dev/null
}

@test "current score matches last entry" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  [ "$(jq '.current' "$TMP/out.json")" -eq 80 ]
}

@test "min/max/avg are computed correctly" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  [ "$(jq '.min' "$TMP/out.json")" -eq 60 ]
  [ "$(jq '.max' "$TMP/out.json")" -eq 80 ]
  [ "$(jq '.avg' "$TMP/out.json")" -eq 70 ]
}

@test "direction is computed from windowed scores" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  [ "$(jq -r '.direction' "$TMP/out.json")" = "up" ]
  # Delta is computed from window: latest (80) vs avg of prior entries in window.
  # Prior 4 entries avg = (60+65+70+75)/4 = 67, delta = 80-67 = 13.
  [ "$(jq '.delta' "$TMP/out.json")" -eq 13 ]
}

@test "sparkline is a non-empty string" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  sparkline=$(jq -r '.sparkline' "$TMP/out.json")
  [ -n "$sparkline" ]
  [ ${#sparkline} -gt 0 ]
}

@test "category_deltas tracks changes" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  count=$(jq '.category_deltas | length' "$TMP/out.json")
  [ "$count" -ge 1 ]
  # missing went from -20 to -10 = delta +10 (improved)
  missing_delta=$(jq '[.category_deltas[] | select(.category == "missing")][0].delta' "$TMP/out.json")
  [ "$missing_delta" -eq 10 ]
}

@test "timeline has correct entry count" {
  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  [ "$(jq '.timeline | length' "$TMP/out.json")" -eq 5 ]
  [ "$(jq '.window_size' "$TMP/out.json")" -eq 5 ]
  [ "$(jq '.total_entries' "$TMP/out.json")" -eq 5 ]
}

# --- --last flag ---

@test "--last slices to requested window" {
  make_health
  bash "$TREND" --target "$REPO" --last 3 > "$TMP/out.json"
  [ "$(jq '.window_size' "$TMP/out.json")" -eq 3 ]
  [ "$(jq '.total_entries' "$TMP/out.json")" -eq 5 ]
  [ "$(jq '.timeline | length' "$TMP/out.json")" -eq 3 ]
}

# --- human format ---

@test "human format produces readable output" {
  make_health
  bash "$TREND" --target "$REPO" --format human > "$TMP/out.txt"
  grep -Fq "Health Score Trend" "$TMP/out.txt"
  grep -Fq "Current:" "$TMP/out.txt"
  grep -Fq "Sparkline:" "$TMP/out.txt"
}

# --- single entry ---

@test "works with a single score entry" {
  cat > "$REPO/memory/health.json" <<'JSON'
{
  "scores": [
    {"timestamp":"2026-04-29T10:00:00Z","score":85,"profile":"default","breakdown":{"missing":-10}}
  ],
  "trend": {"direction":"stable","delta":0,"window_days":7}
}
JSON
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  [ "$(jq '.current' "$TMP/out.json")" -eq 85 ]
  [ "$(jq '.min' "$TMP/out.json")" -eq 85 ]
  [ "$(jq '.max' "$TMP/out.json")" -eq 85 ]
}

# --- error cases ---

@test "missing health file exits non-zero" {
  rm -f "$REPO/memory/health.json"
  run bash "$TREND" --target "$REPO"
  [ "$status" -ne 0 ]
}

@test "empty scores array exits non-zero" {
  echo '{"scores":[],"trend":{"direction":"stable","delta":0,"window_days":7}}' > "$REPO/memory/health.json"
  run bash "$TREND" --target "$REPO"
  [ "$status" -ne 0 ]
}

@test "invalid format dies" {
  make_health
  run bash "$TREND" --target "$REPO" --format xml
  [ "$status" -ne 0 ]
}

@test "--last 0 is rejected" {
  make_health
  run bash "$TREND" --target "$REPO" --last 0
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "positive integer"
}

@test "--last negative is rejected" {
  make_health
  run bash "$TREND" --target "$REPO" --last -1
  [ "$status" -ne 0 ]
}

@test "--last non-numeric is rejected" {
  make_health
  run bash "$TREND" --target "$REPO" --last abc
  [ "$status" -ne 0 ]
}

# --- schema validation ---

@test "output validates against health-trend schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  make_health
  bash "$TREND" --target "$REPO" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/health-trend.schema.json" "$TMP/out.json"
}
