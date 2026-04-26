#!/usr/bin/env bats
# bin/diagnose.sh — support-grade bundle.
# The non-negotiable contract: URL credentials never reach stdout. Other
# tests cover happy-path JSON shape; this file exists to lock the
# redaction guarantee against regressions.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DIAGNOSE="${REPO_ROOT}/bin/diagnose.sh"
  TMP=$(mktemp -d -t nyann-diagnose.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  FAKE_HOME="$TMP/home"
  mkdir -p "$REPO" "$FAKE_HOME/.claude/nyann"
  ( cd "$REPO" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

# ---- happy path -------------------------------------------------------------

@test "emits valid JSON bundle on a bare git repo" {
  out=$(bash "$DIAGNOSE" --target "$REPO" --json 2>/dev/null)
  echo "$out" | jq -e 'has("nyann_version") and has("host") and has("repo") and has("git") and has("hook_files")' >/dev/null
}

@test "exits 0 even when not a git repo (degrades to empty git block)" {
  out=$(bash "$DIAGNOSE" --target "$TMP" --json 2>/dev/null)
  [ "$(echo "$out" | jq '.git.config | length')" = "0" ]
}

@test "validates against schemas/diagnose-bundle.schema.json" {
  command -v uvx >/dev/null 2>&1 || command -v check-jsonschema >/dev/null 2>&1 \
    || skip "no schema validator available"
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  bash "$DIAGNOSE" --target "$REPO" --json 2>/dev/null > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/diagnose-bundle.schema.json" "$TMP/out.json"
}

# ---- redaction is the contract ----------------------------------------------

@test "redacts embedded https://<token>@host URL credentials in git remote" {
  ( cd "$REPO" && git remote add origin "https://abc123-secret-token@github.com/foo/bar.git" )
  out=$(bash "$DIAGNOSE" --target "$REPO" --json 2>/dev/null)
  ! echo "$out" | grep -Fq "abc123-secret-token"
  echo "$out" | jq -r '.git.config[]' | grep -Fq "remote.origin.url=https://***@github.com/foo/bar.git"
}

@test "redacts tokens in team-source URLs from nyann_config" {
  cat > "$FAKE_HOME/.claude/nyann/preferences.json" <<JSON
{
  "schemaVersion": 1,
  "default_profile": "auto-detect",
  "branching_strategy": "auto-detect",
  "commit_format": "conventional-commits",
  "gh_integration": true,
  "documentation_storage": "local",
  "auto_sync_team_profiles": false,
  "setup_completed_at": "2026-04-25T00:00:00Z"
}
JSON
  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{
  "team_profile_sources": [
    {"name": "team-x", "url": "https://team-secret-pat@github.com/team/profiles.git", "ref": "main", "sync_interval_hours": 24, "last_synced_at": 0}
  ]
}
JSON
  out=$(bash "$DIAGNOSE" --target "$REPO" --user-root "$FAKE_HOME/.claude/nyann" --json 2>/dev/null)
  ! echo "$out" | grep -Fq "team-secret-pat"
  url=$(echo "$out" | jq -r '.nyann_config.team_profile_sources[0].url')
  [[ "$url" == "https://***@github.com/team/profiles.git" ]]
}

@test "human-readable mode never includes raw token strings" {
  ( cd "$REPO" && git remote add origin "https://leak-canary-12345@github.com/foo/bar.git" )
  # Default mode (no --json) renders a table to stderr; capture both
  # streams to be safe.
  out=$(bash "$DIAGNOSE" --target "$REPO" 2>&1 || true)
  ! echo "$out" | grep -Fq "leak-canary-12345"
}

# ---- hook content is included but truncated ---------------------------------

@test "includes installed hook content with an 8KB truncation cap" {
  mkdir -p "$REPO/.husky"
  python3 -c "print('x' * 12000)" > "$REPO/.husky/pre-commit"
  out=$(bash "$DIAGNOSE" --target "$REPO" --json 2>/dev/null)
  hook_bytes=$(echo "$out" | jq -r '.hook_files[".husky/pre-commit"]' | wc -c | tr -d ' ')
  # Should be <= 8192 + newline overhead. Way less than 12000.
  [ "$hook_bytes" -le 8200 ]
}
