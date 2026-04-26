#!/usr/bin/env bats
# Regression tests for path-traversal hardening. Each caller refuses a
# plan/input whose path escapes the target / user_root cache root.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-pathtrav.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  mkdir -p "$TMP/repo"
  ( cd "$TMP/repo" && git init -q -b main )
  # Mark a sibling victim file we'd be horrified to see mutated.
  mkdir -p "$TMP/victim"
  echo "important" > "$TMP/victim/keepme.txt"
}

teardown() { rm -rf "$TMP"; }

# ---- bootstrap.sh plan write path --------------------------------------------

@test "bootstrap refuses a plan delete with ../ traversal" {
  # Build a plan that says: delete ../victim/keepme.txt (outside repo).
  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":"../victim/keepme.txt","action":"delete"}],"commands":[],"remote":[]}
JSON
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/default.json" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$TMP/repo" > "$TMP/stack.json"
  sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --emit-sha256 2>/dev/null)

  run bash "${REPO_ROOT}/bin/bootstrap.sh" \
    --target "$TMP/repo" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$sha" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --project-name pt-c1 \
    --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"plan write path"* ]]
  # victim must still exist with content untouched
  [ -f "$TMP/victim/keepme.txt" ]
  [ "$(cat "$TMP/victim/keepme.txt")" = "important" ]
}

@test "bootstrap refuses an absolute plan path" {
  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":"/etc/passwd","action":"delete"}],"commands":[],"remote":[]}
JSON
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/default.json" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$TMP/repo" > "$TMP/stack.json"
  sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --emit-sha256 2>/dev/null)

  run bash "${REPO_ROOT}/bin/bootstrap.sh" \
    --target "$TMP/repo" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$sha" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --project-name pt-c1-abs \
    --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"plan write path"* ]] || [[ "$output" == *"absolute"* ]]
}

# ---- scaffold-docs.sh target path --------------------------------------------

@test "scaffold-docs refuses a documentation-plan target with ../ traversal" {
  # Docplan routing architecture to ../victim/arch.md
  cat > "$TMP/docplan.json" <<JSON
{
  "storage_strategy": "local",
  "targets": {
    "architecture": { "type": "local", "path": "../victim/arch.md" },
    "prd":          { "type": "local", "path": "docs/prd.md" },
    "adrs":         { "type": "local", "path": "docs/decisions" },
    "research":     { "type": "local", "path": "docs/research" },
    "memory":       { "type": "local", "path": "memory" }
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3
}
JSON
  run bash "${REPO_ROOT}/bin/scaffold-docs.sh" \
    --target "$TMP/repo" \
    --plan "$TMP/docplan.json" \
    --project-name pt-c2
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "documentation plan target"
  # victim directory not mutated, nothing written above the repo
  [ ! -f "$TMP/victim/arch.md" ]
}

# ---- release.sh --changelog --------------------------------------------------

@test "release refuses --changelog with ../ traversal" {
  # Give the repo a commit so release.sh gets past its empty-history bail.
  ( cd "$TMP/repo" \
      && git config user.email t@example.com \
      && git config user.name  t \
      && echo "x" > README.md \
      && git add README.md \
      && git commit -q -m "feat: init" )

  run bash "${REPO_ROOT}/bin/release.sh" \
    --target "$TMP/repo" \
    --version 0.1.0 \
    --strategy conventional-changelog \
    --changelog "../victim/CHANGELOG.md" \
    --yes \
    --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--changelog"* ]]
  [ ! -f "$TMP/victim/CHANGELOG.md" ]
}

@test "release refuses absolute --changelog" {
  ( cd "$TMP/repo" \
      && git config user.email t@example.com \
      && git config user.name  t \
      && echo "x" > README.md \
      && git add README.md \
      && git commit -q -m "feat: init" )

  run bash "${REPO_ROOT}/bin/release.sh" \
    --target "$TMP/repo" \
    --version 0.1.0 \
    --strategy conventional-changelog \
    --changelog "/tmp/nyann-should-not-write.md" \
    --yes \
    --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--changelog"* ]]
  [ ! -f "/tmp/nyann-should-not-write.md" ]
}

# ---- sync-team-profiles re-validates name ------------------------------------

@test "sync-team-profiles rejects a config source with traversal name" {
  # Hand-crafted config — simulating a file that bypassed add-team-source.
  FAKE_HOME="$TMP/home"
  mkdir -p "$FAKE_HOME/.claude/nyann"
  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{
  "team_profile_sources": [
    { "name": "../Works/important-repo", "url": "https://example.invalid/x.git", "ref": "main", "sync_interval_hours": 24, "last_synced_at": 0 }
  ]
}
JSON

  # The script shouldn't touch anything outside its cache, even on an
  # attempted sync. Run it once and check output.
  run env HOME="$FAKE_HOME" bash "${REPO_ROOT}/bin/sync-team-profiles.sh"
  [ "$status" -eq 0 ]
  # The source should appear in `invalid[]` with kind=invalid-name.
  echo "$output" | jq -e '.invalid | map(select(.kind == "invalid-name")) | length == 1' >/dev/null
  # No cache directory materialised for the escape name.
  [ ! -d "$FAKE_HOME/.claude/nyann/cache/../Works/important-repo" ]
}
