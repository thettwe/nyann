#!/usr/bin/env bats
# Regressions for path-safety: --dir traversal in record-decision,
# name re-validation in check-team-drift, and symlink refusal in
# bootstrap editorconfig / gitignore-combiner / scaffold-docs.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-r2gaps.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )
  # Mark a sentinel we'd be horrified to see mutated.
  mkdir -p "$TMP/victim"
  echo "do-not-touch" > "$TMP/victim/keepme"
}

teardown() { rm -rf "$TMP"; }

# ---- record-decision --dir traversal ----------------------------------------

@test "record-decision refuses --dir with ../ traversal" {
  run bash "${REPO_ROOT}/bin/record-decision.sh" \
    --target "$REPO" \
    --title "Test ADR" \
    --dir "../victim" \
    --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF -- "--dir"
  # victim untouched
  [ "$(cat "$TMP/victim/keepme")" = "do-not-touch" ]
}

@test "record-decision refuses absolute --dir" {
  run bash "${REPO_ROOT}/bin/record-decision.sh" \
    --target "$REPO" \
    --title "Test ADR" \
    --dir "/tmp/nyann-should-not-reach" \
    --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF -- "--dir"
  [ ! -e "/tmp/nyann-should-not-reach" ]
}

@test "record-decision accepts a normal relative --dir" {
  run bash "${REPO_ROOT}/bin/record-decision.sh" \
    --target "$REPO" \
    --title "Test ADR" \
    --dir "docs/decisions" \
    --dry-run
  [ "$status" -eq 0 ]
}

# ---- check-team-drift re-validates name -------------------------------------

@test "check-team-drift rejects a config source with traversal name" {
  FAKE_HOME="$TMP/home"
  mkdir -p "$FAKE_HOME/.claude/nyann"
  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{
  "team_profile_sources": [
    { "name": "../Works/important-repo", "url": "https://example.invalid/x.git", "ref": "main", "sync_interval_hours": 24, "last_synced_at": 0 }
  ]
}
JSON
  run env HOME="$FAKE_HOME" bash "${REPO_ROOT}/bin/check-team-drift.sh" --offline
  [ "$status" -eq 0 ]
  # Entry must appear in unreachable[] with an error about the invalid name.
  echo "$output" | jq -e '[.unreachable[] | select(.error | test("invalid source name|escapes cache_root"))] | length >= 1' >/dev/null
  # No cache dir was created outside the cache root.
  [ ! -d "$FAKE_HOME/.claude/nyann/cache/../Works/important-repo" ]
}

# ---- symlink refusal at editorconfig, gitignore-combiner, scaffold-docs -----

@test "bootstrap refuses .editorconfig via symlink" {
  # Dangling symlink pointing INSIDE the repo so assert_path_under_target
  # doesn't reject it as an escape — the -L guard in the editorconfig
  # section is what must fire.
  ln -s "$REPO/nonexistent.editorconfig" "$REPO/.editorconfig"

  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".editorconfig","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  plan_sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --emit-sha256)
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/default.json" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"

  run bash "${REPO_ROOT}/bin/bootstrap.sh" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$plan_sha" \
    --profile "${REPO_ROOT}/profiles/typescript-library.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "symlink"
  # Symlink target was not created by the write.
  [ ! -f "$REPO/nonexistent.editorconfig" ]
}

@test "gitignore-combiner refuses symlinked --target" {
  sentinel="$TMP/victim/sentinel-gitignore.txt"
  echo "original" > "$sentinel"
  ln -s "$sentinel" "$REPO/.gitignore"

  run bash "${REPO_ROOT}/bin/gitignore-combiner.sh" \
    --target "$REPO/.gitignore" \
    --templates "generic"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "symlink"
  [ "$(cat "$sentinel")" = "original" ]
}

@test "scaffold-docs refuses a dangling-symlink destination" {
  # Plant a dangling symlink where scaffold-docs would write
  # `docs/prd.md`. The symlink must point INSIDE the repo (so
  # safe_target_path doesn't reject it as an escape) but to a
  # non-existent file (so -e is false and -L fires).
  mkdir -p "$REPO/docs"
  ln -s "$REPO/docs/nonexistent-target.md" "$REPO/docs/prd.md"

  cat > "$TMP/docplan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "architecture": { "type": "local", "path": "docs/architecture.md" },
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
    --target "$REPO" \
    --plan "$TMP/docplan.json" \
    --project-name test-rh6
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "symlink"
  [ ! -f "$REPO/docs/nonexistent-target.md" ]
}
