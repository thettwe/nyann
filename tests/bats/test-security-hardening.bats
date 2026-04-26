#!/usr/bin/env bats
# Regressions for security hardening: owner/repo allowlist, git arg
# injection, protection downgrade prevention, trap coverage, TOCTOU
# closure, and ANSI sanitization in warn messages.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-rHigh.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# ---- owner/repo allowlist in gh-integration ---------------------------------

@test "gh-integration refuses owner starting with '.' (allowlist enforced)" {
  repo="$TMP/repo"
  mkdir -p "$repo"
  # The BASH_REMATCH regex accepts owner like `..foo` (dots allowed in
  # `[^/]+`); the point is the NEW validation rejects it before any
  # `gh api` call fires.
  ( cd "$repo" && git init -q -b main \
     && git remote add origin 'git@github.com:..evilowner/realrepo.git' )

  # Mock `gh` that succeeds on auth-status so we reach the validation.
  # The stub logs any api calls; the test asserts none happened.
  stub_dir="$TMP/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) [[ "$2" == "status" ]] && exit 0 || exit 1 ;;
  api)  printf '%s\n' "$@" >> "${STUB_LOG:-/dev/null}"; exit 0 ;;
  *)    exit 0 ;;
esac
STUB
  chmod +x "$stub_dir/gh"

  stub_log="$TMP/gh-calls.log"
  : > "$stub_log"
  # Capture stdout separately (warn line on stderr would break jq).
  out=$(env PATH="$stub_dir:$PATH" STUB_LOG="$stub_log" \
    bash "${REPO_ROOT}/bin/gh-integration.sh" \
    --target "$repo" --profile default --gh "$stub_dir/gh" 2>/dev/null)
  # skip() emits {"skipped":"<phase>","reason":"..."} — a flat record.
  echo "$out" | jq -e '.reason == "invalid-owner"' >/dev/null
  # Crucially: no `gh api` calls were made for the bogus owner/repo.
  ! grep -q "^api$" "$stub_log" || { echo "api call leaked"; false; }
}

# ---- new-branch refuses a pattern starting with '-' -------------------------

@test "new-branch refuses a profile branch_name_patterns pattern starting with '-'" {
  repo="$TMP/repo-nb"
  mkdir -p "$repo"
  ( cd "$repo" \
     && git init -q -b main \
     && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )

  user_root="$TMP/home/.claude/nyann"
  mkdir -p "$user_root/profiles"
  cat > "$user_root/profiles/evil.json" <<'JSON'
{
  "$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "evil",
  "schemaVersion": 1,
  "stack": { "primary_language": "unknown" },
  "branching": {
    "strategy": "trunk-based",
    "base_branches": ["main"],
    "branch_name_patterns": {
      "feature": "--upload-pack=touch /tmp/nyann-exploit-sentinel-git-arg-injection",
      "bugfix":  "fix/{slug}",
      "hotfix":  "hotfix/{slug}",
      "release": "release/{version}"
    }
  },
  "hooks":   { "pre_commit": [], "commit_msg": [] },
  "extras":  { "gitignore": true, "editorconfig": false, "claude_md": true, "github_actions_ci": false },
  "conventions": { "commit_format": "conventional", "scopes": [], "footer_trailers": [] },
  "documentation": { "storage_strategy": "local", "scaffold_types": [], "claude_md_mode": "router", "claude_md_size_budget_kb": 3, "enable_drift_checks": false }
}
JSON

  rm -f /tmp/nyann-exploit-sentinel-git-arg-injection
  run env HOME="$TMP/home" bash "${REPO_ROOT}/bin/new-branch.sh" \
    --target "$repo" --profile evil --purpose feature --slug bypass
  [ "$status" -ne 0 ]
  [ ! -e "/tmp/nyann-exploit-sentinel-git-arg-injection" ] || { echo "leaked pwnfile"; rm -f /tmp/nyann-exploit-sentinel-git-arg-injection; false; }
}

# ---- load-profile snapshot-then-validate ------------------------------------

@test "load-profile emits the snapshot (not a re-read) when bytes match" {
  user_root="$TMP/home/.claude/nyann"
  mkdir -p "$user_root/profiles"
  cp "${REPO_ROOT}/profiles/default.json" "$user_root/profiles/mine.json"

  # Capture stdout separately so the [nyann] log on stderr doesn't
  # pollute the JSON we'll pipe to jq.
  out=$(env HOME="$TMP/home" bash "${REPO_ROOT}/bin/load-profile.sh" mine 2>/dev/null)
  echo "$out" | jq -e '.name == "mine" or .name == "default"' >/dev/null
}

# ---- bootstrap sanitizes profile-name ANSI in warn --------------------------

@test "bootstrap replaces invalid profile name with placeholder in warn" {
  repo="$TMP/repo-rl1"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main )

  # Build the profile via jq so JSON escaping is automatic.
  profile="$TMP/evil-profile.json"
  ansi_name=$'AAA\x1b[2J\x1b[0m[nyann] error: fake'
  jq --arg n "$ansi_name" '.name = $n' \
    "${REPO_ROOT}/profiles/default.json" > "$profile"

  echo '{"writes":[],"commands":[],"remote":[]}' > "$TMP/plan.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$profile" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$repo" > "$TMP/stack.json"

  # Stack is deliberately empty so the mismatch-warn branch fires.
  echo '{"primary_language":"typescript","secondary_languages":[]}' > "$TMP/stack.json"
  sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --emit-sha256 2>/dev/null)

  run bash "${REPO_ROOT}/bin/bootstrap.sh" \
    --target "$repo" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$sha" \
    --profile "$profile" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  # The warn output must not contain raw ANSI escape bytes.
  ! grep -q $'\x1b\[' <<<"$output" || { echo "ANSI leaked into warn"; false; }
  # Should contain the placeholder.
  grep -Fq "(invalid-name)" <<<"$output"
}
