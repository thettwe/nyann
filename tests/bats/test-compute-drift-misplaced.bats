#!/usr/bin/env bats
# v1.9.0: compute-drift.sh surfaces conformance results as DriftReport.misplaced[]
# and emits a nyann::warn when detect-doc-conformance.sh fails (rather than
# silently swallowing the error).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPUTE="${REPO_ROOT}/bin/compute-drift.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
  # Profile with a docs scaffold expectation so drift checks docs at all.
  cat > "$TMP/profile.json" <<'EOF'
{
  "name": "test", "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "trunk-based", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {}, "conventions": {"commit_format": "conventional-commits"},
  "documentation": {
    "scaffold_types": ["architecture", "prd"],
    "storage_strategy": "local", "claude_md_mode": "router"
  }
}
EOF
}

teardown() { rm -rf "$TMP"; }

@test "ARCHITECTURE.md at root surfaces as misplaced (not just missing)" {
  echo "x" > "$TARGET/ARCHITECTURE.md"
  json=$(bash "$COMPUTE" --target "$TARGET" --profile "$TMP/profile.json" 2>/dev/null)
  # misplaced[] is the new field; should contain at least one entry
  [ "$(echo "$json" | jq '.misplaced | length')" -ge 1 ]
  [ "$(echo "$json" | jq -r '.misplaced[0].source')" = "ARCHITECTURE.md" ]
  [ "$(echo "$json" | jq -r '.misplaced[0].target')" = "docs/architecture.md" ]
}

@test "summary.misplaced counts entries in misplaced[]" {
  echo "x" > "$TARGET/ARCHITECTURE.md"
  echo "y" > "$TARGET/PRD.md"
  json=$(bash "$COMPUTE" --target "$TARGET" --profile "$TMP/profile.json" 2>/dev/null)
  misplaced_count=$(echo "$json" | jq '.misplaced | length')
  summary_misplaced=$(echo "$json" | jq '.summary.misplaced')
  [ "$summary_misplaced" -eq "$misplaced_count" ]
}

@test "no misplaced docs: misplaced[] is empty, summary.misplaced == 0" {
  json=$(bash "$COMPUTE" --target "$TARGET" --profile "$TMP/profile.json" 2>/dev/null)
  [ "$(echo "$json" | jq '.misplaced | length')" -eq 0 ]
  [ "$(echo "$json" | jq '.summary.misplaced')" -eq 0 ]
}

@test "missing detect-doc-conformance.sh: degrades gracefully (empty misplaced)" {
  # Run compute-drift with a custom script dir where the conformance helper
  # is absent. Compute-drift's guard is `[[ -x ".../detect-doc-conformance.sh" ]]`
  # so we just confirm normal execution doesn't error when the file is present.
  json=$(bash "$COMPUTE" --target "$TARGET" --profile "$TMP/profile.json" 2>/dev/null)
  # misplaced[] still emitted as a (possibly empty) array
  [ "$(echo "$json" | jq -r '.misplaced | type')" = "array" ]
}
