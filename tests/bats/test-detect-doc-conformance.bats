#!/usr/bin/env bats
# Tests for bin/detect-doc-conformance.sh — non-canonical doc path scanner.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CONF="${REPO_ROOT}/bin/detect-doc-conformance.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
}

teardown() { rm -rf "$TMP"; }

# Helper: capture clean stdout JSON (stderr stripped). Returns the JSON
# array string; tests can pipe it through jq.
conf_for() {
  bash "$CONF" --target "$1" ${2:+--archetype "$2"} 2>/dev/null
}

@test "empty repo: emits an empty array, exit 0" {
  json=$(conf_for "$TARGET")
  [ "$(echo "$json" | jq 'length')" -eq 0 ]
}

@test "root-level ARCHITECTURE.md proposes docs/architecture.md" {
  echo "x" > "$TARGET/ARCHITECTURE.md"
  json=$(conf_for "$TARGET")
  [ "$(echo "$json" | jq '[.[] | select(.category == "architecture")] | length')" -ge 1 ]
  [ "$(echo "$json" | jq -r '[.[] | select(.category == "architecture")][0].target')" = "docs/architecture.md" ]
  [ "$(echo "$json" | jq -r '[.[] | select(.category == "architecture")][0].source')" = "ARCHITECTURE.md" ]
}

@test "canonical path already exists: no proposal for that category" {
  mkdir -p "$TARGET/docs"
  echo "x" > "$TARGET/ARCHITECTURE.md"
  echo "y" > "$TARGET/docs/architecture.md"
  json=$(conf_for "$TARGET")
  [ "$(echo "$json" | jq '[.[] | select(.source == "ARCHITECTURE.md")] | length')" -eq 0 ]
}

@test "archetype filters categories: cli-tool excludes api-reference proposals" {
  # api-reference patterns include docs/api.md, docs/openapi.md, etc.
  mkdir -p "$TARGET/docs"
  echo "x" > "$TARGET/docs/api.md"
  json=$(conf_for "$TARGET" "cli-tool")
  [ "$(echo "$json" | jq '[.[] | select(.category == "api_reference")] | length')" -eq 0 ]
}

@test "archetype api-service: api-reference is included" {
  mkdir -p "$TARGET/docs"
  echo "x" > "$TARGET/docs/api.md"
  json=$(conf_for "$TARGET" "api-service")
  [ "$(echo "$json" | jq '[.[] | select(.category == "api_reference")] | length')" -ge 1 ]
}

@test "dedup: multiple patterns hitting one canonical target collapse to one" {
  # Both ARCHITECTURE.md and design.md propose docs/architecture.md.
  # group_by(.target) keeps only the highest-confidence proposal.
  echo "x" > "$TARGET/ARCHITECTURE.md"
  echo "y" > "$TARGET/design.md"
  json=$(conf_for "$TARGET")
  [ "$(echo "$json" | jq '[.[] | select(.target == "docs/architecture.md")] | length')" -eq 1 ]
}

@test "unknown archetype falls through to broad scope (architecture + prd + adrs + research)" {
  echo "x" > "$TARGET/PRD.md"
  json=$(conf_for "$TARGET" "not-a-real-archetype")
  # Unknown case → relevant_types stays at default. PRD should still be detected.
  [ "$(echo "$json" | jq '[.[] | select(.category == "prd")] | length')" -ge 1 ]
}

@test "schema: each proposal has source, target, category, confidence, reason" {
  echo "x" > "$TARGET/ARCHITECTURE.md"
  json=$(conf_for "$TARGET")
  entry=$(echo "$json" | jq -c '.[0]')
  [ -n "$(echo "$entry" | jq -r '.source')" ]
  [ -n "$(echo "$entry" | jq -r '.target')" ]
  [ -n "$(echo "$entry" | jq -r '.category')" ]
  [ -n "$(echo "$entry" | jq -r '.confidence')" ]
  [ -n "$(echo "$entry" | jq -r '.reason')" ]
}

@test "missing --target dies with a clear message" {
  run bash "$CONF"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "target"
}

@test "ADR directory at non-canonical path: adr/ proposes docs/decisions/" {
  mkdir -p "$TARGET/adr"
  json=$(conf_for "$TARGET")
  [ "$(echo "$json" | jq '[.[] | select(.category == "adrs")] | length')" -ge 1 ]
  [ "$(echo "$json" | jq -r '[.[] | select(.category == "adrs")][0].target')" = "docs/decisions" ]
}
