#!/usr/bin/env bats
# bin/gen-templates.sh — GitHub PR and issue template generation tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-templates.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"

  PROFILE="$TMP/profile.json"
  cp "${REPO_ROOT}/profiles/nextjs-prototype.json" "$PROFILE"
}

teardown() { rm -rf "$TMP"; }

run_gen() {
  bash "$GEN" --profile "$PROFILE" --target "$REPO" "$@"
}

# --- PR template rendering ---

@test "generates PR template with hook-derived checklist" {
  run run_gen
  [ "$status" -eq 0 ]
  [ -f "$REPO/.github/PULL_REQUEST_TEMPLATE.md" ]
  grep -Fq 'eslint' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq 'prettier' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "PR template includes scope section from profile conventions" {
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq 'Scope' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq '`ui`' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq '`api`' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "profile with no scopes → no scope section" {
  jq '.conventions.commit_scopes = []' "$PROFILE" > "${PROFILE}.tmp" && mv "${PROFILE}.tmp" "$PROFILE"
  run run_gen
  [ "$status" -eq 0 ]
  ! grep -Fq 'Scope' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "python profile → ruff in checklist" {
  cp "${REPO_ROOT}/profiles/python-cli.json" "$PROFILE"
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq 'ruff' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

# --- Issue templates ---

@test "generates all issue template files" {
  run run_gen
  [ "$status" -eq 0 ]
  [ -f "$REPO/.github/ISSUE_TEMPLATE/bug_report.md" ]
  [ -f "$REPO/.github/ISSUE_TEMPLATE/feature_request.md" ]
  [ -f "$REPO/.github/ISSUE_TEMPLATE/config.yml" ]
}

@test "bug report template has YAML frontmatter" {
  run run_gen
  [ "$status" -eq 0 ]
  head -1 "$REPO/.github/ISSUE_TEMPLATE/bug_report.md" | grep -Fq -- '---'
  grep -Fq 'labels: bug' "$REPO/.github/ISSUE_TEMPLATE/bug_report.md"
}

# --- Marker-aware re-run semantics ---

@test "fresh write wraps content in nyann markers" {
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq '<!-- nyann:templates:start -->' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq '<!-- nyann:templates:end -->' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "issue templates keep YAML frontmatter above the start marker" {
  run run_gen
  [ "$status" -eq 0 ]
  # Frontmatter must remain on line 1; the start marker comes after the
  # closing `---`. Otherwise GitHub stops parsing the template.
  head -1 "$REPO/.github/ISSUE_TEMPLATE/bug_report.md" | grep -Fxq -- '---'
  # First nyann marker should appear AFTER the first two `---` lines.
  marker_line=$(grep -n '<!-- nyann:templates:start -->' "$REPO/.github/ISSUE_TEMPLATE/bug_report.md" | cut -d: -f1 | head -1)
  [ "$marker_line" -gt 2 ]
}

@test "existing markerless PR template is skipped without --allow-merge-existing" {
  mkdir -p "$REPO/.github"
  echo "custom content" > "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fxq "custom content" "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  # No marker leaked into the user's file.
  ! grep -Fq '<!-- nyann:templates:start -->' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "--allow-merge-existing appends marked block, preserving user content" {
  mkdir -p "$REPO/.github"
  echo "custom content" > "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  run run_gen --allow-merge-existing
  [ "$status" -eq 0 ]
  # User content is still present.
  grep -Fxq "custom content" "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  # Marked nyann block was appended.
  grep -Fq '<!-- nyann:templates:start -->' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq 'Checklist' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "--force is a back-compat alias for --allow-merge-existing" {
  mkdir -p "$REPO/.github"
  echo "custom content" > "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  run run_gen --force
  [ "$status" -eq 0 ]
  # Same outcome as --allow-merge-existing: append, never silently overwrite.
  grep -Fxq "custom content" "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq '<!-- nyann:templates:start -->' "$REPO/.github/PULL_REQUEST_TEMPLATE.md"
}

@test "re-run on a marker-bracketed file is idempotent" {
  run run_gen
  [ "$status" -eq 0 ]
  sha1=$(shasum -a 256 "$REPO/.github/PULL_REQUEST_TEMPLATE.md" | awk '{print $1}')
  run run_gen
  [ "$status" -eq 0 ]
  sha2=$(shasum -a 256 "$REPO/.github/PULL_REQUEST_TEMPLATE.md" | awk '{print $1}')
  [ "$sha1" = "$sha2" ]
}

# --- Dry-run ---

@test "dry-run does not write files" {
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$REPO/.github/PULL_REQUEST_TEMPLATE.md" ]
  [ ! -d "$REPO/.github/ISSUE_TEMPLATE" ]
}

# --- Error cases ---

@test "missing --profile → dies" {
  run bash "$GEN" --target "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile"* ]]
}
