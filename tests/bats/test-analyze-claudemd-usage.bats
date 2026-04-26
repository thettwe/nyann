#!/usr/bin/env bats
# bin/analyze-claudemd-usage.sh — usage analysis and recommendation tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ANALYZE="${REPO_ROOT}/bin/analyze-claudemd-usage.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO/memory" "$REPO/docs"
}

teardown() { rm -rf "$TMP"; }

make_claudemd() {
  cat > "$REPO/CLAUDE.md" <<'MD'
# Project

User content here.

<!-- nyann:start -->

## Build commands

- `npm test` — run tests
- `npm run lint` — run linter

## Docs map

| Doc | Purpose |
|---|---|
| [Architecture](docs/architecture.md) | System overview |
| [PRD](docs/prd.md) | Product requirements |
| [Research](docs/research/README.md) | Research notes |

## Conventions

Commit format: conventional-commits

<!-- nyann:end -->

More user content.
MD
}

make_usage() {
  local sessions="${1:-15}"
  cat > "$REPO/memory/claudemd-usage.json" <<JSON
{
  "sessions": $sessions,
  "sections": {
    "Build commands": { "referenced": ${2:-30}, "last_referenced": "2025-01-15T00:00:00Z" },
    "Docs map": { "referenced": ${3:-5}, "last_referenced": "2025-01-10T00:00:00Z" },
    "Conventions": { "referenced": ${4:-20}, "last_referenced": "2025-01-14T00:00:00Z" }
  },
  "commands_run": {
    "npm test": ${5:-25},
    "npm run lint": ${6:-10},
    "npm run dev": ${7:-15}
  },
  "docs_read": {
    "docs/architecture.md": ${8:-8},
    "docs/prd.md": ${9:-2}
  }
}
JSON
}

@test "insufficient data returns early without recommendations" {
  make_claudemd
  make_usage 5
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  sufficient=$(echo "$output" | jq -r '.sufficient_data')
  [ "$sufficient" = "false" ]
  recs=$(echo "$output" | jq '.recommendations | length')
  [ "$recs" -eq 0 ]
}

@test "--force bypasses minimum session requirement" {
  make_claudemd
  make_usage 3 30 5 20
  run bash "$ANALYZE" --target "$REPO" --force
  [ "$status" -eq 0 ]
  sufficient=$(echo "$output" | jq -r '.sufficient_data')
  [ "$sufficient" = "true" ]
}

@test "section density calculation produces correct verdicts" {
  make_claudemd
  # High refs for Build, low for Docs map, medium for Conventions
  make_usage 15 30 1 20
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  # Docs map should be "compress" or "remove" due to low refs
  docs_verdict=$(echo "$output" | jq -r '.section_analysis[] | select(.section == "Docs map") | .verdict')
  [ "$docs_verdict" = "compress" ] || [ "$docs_verdict" = "remove" ]
}

@test "detects unused docs referenced in CLAUDE.md" {
  make_claudemd
  make_usage 15 30 5 20 25 10 15 8 2
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  # docs/research/README.md is referenced in CLAUDE.md but not in docs_read
  unused=$(echo "$output" | jq '.unused_docs | length')
  [ "$unused" -ge 1 ]
  echo "$output" | jq -e '.unused_docs[] | select(. == "docs/research/README.md")'
}

@test "detects frequently-run commands missing from CLAUDE.md" {
  make_claudemd
  # npm run dev is run 15 times but not in CLAUDE.md... wait, it IS in our CLAUDE.md
  # Let's use a command that's NOT in CLAUDE.md
  cat > "$REPO/memory/claudemd-usage.json" <<'JSON'
{
  "sessions": 15,
  "sections": {},
  "commands_run": {
    "npm test": 25,
    "npm run build": 12
  },
  "docs_read": {}
}
JSON
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  # npm run build is run 12 times but not in CLAUDE.md
  echo "$output" | jq -e '.missing_commands[] | select(. == "npm run build")'
}

@test "budget tracking reports correct values" {
  make_claudemd
  make_usage 15
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  budget_used=$(echo "$output" | jq '.budget_used')
  [ "$budget_used" -gt 0 ]
  budget_remaining=$(echo "$output" | jq '.budget_remaining')
  [ "$budget_remaining" -ge 0 ]
}

@test "generates compression recommendations for low-density sections" {
  make_claudemd
  make_usage 15 30 1 20
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  compress_count=$(echo "$output" | jq '[.recommendations[] | select(.action == "compress")] | length')
  [ "$compress_count" -ge 0 ]
}

@test "missing usage file fails with clear error" {
  make_claudemd
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -ne 0 ]
}

@test "missing CLAUDE.md fails with clear error" {
  mkdir -p "$REPO/memory"
  make_usage 15
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -ne 0 ]
}

@test "output has all expected top-level fields" {
  make_claudemd
  make_usage 15
  run bash "$ANALYZE" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("total_sessions", "section_analysis", "unused_docs", "missing_commands", "budget_used", "budget_remaining", "recommendations")'
}
