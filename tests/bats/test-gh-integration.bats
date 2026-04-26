#!/usr/bin/env bats
# bin/gh-integration.sh: guards + mock-gh happy path. Never touches real GitHub.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/bin/gh-integration.sh"
  TMP="$(mktemp -d)"
  UR="$TMP/user-root"
  mkdir -p "$UR/profiles"
  # A profile that asks for protection on main.
  cat > "$UR/profiles/protect-me.json" <<JSON
{
  "\$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "protect-me",
  "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "github": {"enable_branch_protection": true, "require_pr_reviews": 1, "require_status_checks": []},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
JSON
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
  ( cd "$TARGET" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" && git remote add origin git@github.com:nyann/fake.git )
}

teardown() { rm -rf "$TMP"; }

@test "gh missing → skip gh-not-installed" {
  # CI Ubuntu runners ship gh in /usr/bin, so /usr/bin:/bin still finds
  # it. Use a scratch dir with every dep nyann's script touches except
  # gh itself. This guarantees the gh guard fires first, regardless of
  # how pristine (or not) the runner's /usr/bin is.
  empty_bin="$TMP/empty-bin"
  mkdir -p "$empty_bin"
  for exe in jq git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum python3 bash; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$empty_bin/$exe" 2>/dev/null || true
  done
  run env -i HOME="$HOME" PATH="$empty_bin" bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"reason": "gh-not-installed"'
}

@test "gh present but unauthed → skip gh-not-authenticated" {
  mock_dir="$TMP/mock"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'SH'
#!/bin/sh
case "$1" in auth) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$mock_dir/gh"
  run bash "$SCRIPT" --profile protect-me --target "$TARGET" --gh "$mock_dir/gh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"reason": "gh-not-authenticated"'
}

@test "profile disables protection → skip profile-disabled-branch-protection" {
  mock_dir="$TMP/mock"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'SH'
#!/bin/sh
case "$1" in auth) exit 0 ;; api) echo '{}'; exit 0 ;; *) exit 0 ;; esac
SH
  chmod +x "$mock_dir/gh"
  jq '.github.enable_branch_protection = false' "$UR/profiles/protect-me.json" > "$UR/profiles/protect-me.json.new"
  mv "$UR/profiles/protect-me.json.new" "$UR/profiles/protect-me.json"
  run bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" --gh "$mock_dir/gh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"reason": "profile-disabled-branch-protection"'
}

@test "missing --profile → dies with error" {
  run bash "$SCRIPT" --target "$TARGET"
  [ "$status" -ne 0 ]
}

@test "missing --target defaults to the current repo" {
  mock_dir="$TMP/mock-default-target"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    case "$*" in
      *"--method GET"*)  echo '{}' ;;
      *"--method PUT"*)  echo '{"ok":true}' ;;
    esac
    exit 0 ;;
esac
SH
  chmod +x "$mock_dir/gh"
  run bash -lc "cd \"$TARGET\" && \"$SCRIPT\" --profile protect-me --user-root \"$UR\" --owner nyann --repo fake --gh \"$mock_dir/gh\""
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.applied[0].branch')" = "main" ]
}

@test "happy path → applied[] has main with strategy=github-flow" {
  mock_dir="$TMP/mock"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    case "$*" in
      *"--method GET"*)  echo '{}' ;;
      *"--method PUT"*)  echo '{"ok":true}' ;;
    esac
    exit 0 ;;
esac
SH
  chmod +x "$mock_dir/gh"
  run bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$mock_dir/gh"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.applied[0].branch')" = "main" ]
  [ "$(echo "$output" | jq -r '.applied[0].strategy')" = "github-flow" ]
}

# ---- --check (read-only audit) --------------------------------------------
# The audit path emits a ProtectionAudit JSON instead of writing
# anything. Doctor consumes the same shape; this lock asserts the
# happy + missing-protection cases.

# Mock gh that returns "Branch not protected" for any GET on
# .../branches/.../protection. Used for the missing-protection branch.
make_mock_gh_no_protection() {
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    case "$*" in
      *"branches"*"protection"*) echo '{"message":"Branch not protected"}'; exit 0 ;;
    esac
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "--check on a branch with no protection → critical drift" {
  make_mock_gh_no_protection
  run bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check
  [ "$status" -eq 0 ]
  # Top-level shape matches the schema: branches[], summary, etc.
  echo "$output" | jq -e '.branches | length == 1' >/dev/null
  echo "$output" | jq -e '.branches[0].name == "main"' >/dev/null
  echo "$output" | jq -e '.branches[0].actual == null' >/dev/null
  echo "$output" | jq -e '.summary.critical >= 1' >/dev/null
  # Per-field drift includes branch_protection_present:critical.
  echo "$output" | jq -e '
    [.branches[0].drift[] | select(.field == "branch_protection_present" and .severity == "critical")]
    | length == 1
  ' >/dev/null
}

@test "--check output validates against protection-audit schema" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  make_mock_gh_no_protection
  out_file="$TMP/audit.json"
  bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/protection-audit.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/protection-audit.schema.json" "$out_file"
  fi
}

# ---- --check tag protection (Rulesets API) --------------------------------
# Profile field `.github.tag_protection_pattern` enables auditing the
# Rulesets API for a tag-targeting ruleset that blocks deletion +
# force-push. Three states: pattern not declared (skipped), declared
# but no matching ruleset (critical), declared and matching (clean).

# Profile-with-tag fixture used by the next 3 tests.
write_profile_with_tag() {
  cat > "$UR/profiles/with-tag.json" <<JSON
{
  "\$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "with-tag",
  "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "github": {"enable_branch_protection": true, "tag_protection_pattern": "v*"},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
JSON
}

# Mock gh that responds to the Rulesets endpoints. Default behaviour:
# branches not protected; tags protected via ruleset id 42 with both
# deletion + non_fast_forward rules.
make_mock_gh_with_tag_ruleset() {
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets/*) echo '{"id":42,"name":"protect-tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}'; exit 0 ;;
        */rulesets) echo '[{"id":42,"name":"protect-tags"}]'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "--check tag protection: matching ruleset → no tag drift, ruleset_id captured" {
  write_profile_with_tag
  make_mock_gh_with_tag_ruleset
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.tag_protection.pattern_present == true' >/dev/null
  echo "$out" | jq -e '.tag_protection.blocks_deletion == true' >/dev/null
  echo "$out" | jq -e '.tag_protection.blocks_force_push == true' >/dev/null
  echo "$out" | jq -e '.tag_protection.ruleset_id == 42' >/dev/null
  echo "$out" | jq -e '.tag_protection.drift | length == 0' >/dev/null
}

@test "--check tag protection: empty rulesets → critical pattern_present drift" {
  write_profile_with_tag
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */rulesets) echo '[]'; exit 0 ;;
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.tag_protection.pattern_present == false' >/dev/null
  echo "$out" | jq -e '
    [.tag_protection.drift[] | select(.field == "pattern_present" and .severity == "critical")]
    | length == 1
  ' >/dev/null
}

@test "--check tag protection: profile without pattern → tag_protection skipped" {
  # protect-me has no tag_protection_pattern → audit skips that section.
  make_mock_gh_with_tag_ruleset
  out=$(bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.tag_protection.skipped == true' >/dev/null
  echo "$out" | jq -e '.tag_protection.reason == "tag-protection-not-configured-in-profile"' >/dev/null
  echo "$out" | jq -e '.summary.skipped_sections | index("tag_protection") != null' >/dev/null
}

@test "--check tag protection: matching ruleset missing one rule → critical drift" {
  # Ruleset matches v* but lacks non_fast_forward. blocks_force_push
  # should report false; drift should include the field.
  write_profile_with_tag
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets/*) echo '{"id":42,"name":"protect-tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"}]}'; exit 0 ;;
        */rulesets) echo '[{"id":42,"name":"protect-tags"}]'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.tag_protection.blocks_deletion == true' >/dev/null
  echo "$out" | jq -e '.tag_protection.blocks_force_push == false' >/dev/null
  echo "$out" | jq -e '
    [.tag_protection.drift[] | select(.field == "blocks_force_push" and .severity == "critical")]
    | length == 1
  ' >/dev/null
}

# ---- --check repo security audit -----------------------------------------
# Reads four signals: Dependabot alerts (vulnerability-alerts 204/404),
# secret scanning + push protection (security_and_analysis on the repo
# meta), and code-scanning default setup (.state). Drift is `warn`
# severity because these are good-practice gates, not preview-mutate
# invariants.

# Mock that responds to all four security endpoints with "enabled"
# values plus the rest of the audit's expected calls. The repo-meta
# response is enriched with id (so the security section sees a real
# repo) and default_branch + merge buttons so the repo_settings audit
# sees a complete picture.
make_mock_gh_security_all_enabled() {
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets/*) echo '{"id":42,"name":"protect-tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}'; exit 0 ;;
        */rulesets) echo '[{"id":42,"name":"protect-tags"}]'; exit 0 ;;
        */vulnerability-alerts) exit 0 ;;
        */code-scanning/default-setup) echo '{"state":"configured"}'; exit 0 ;;
        */repos/*/*) echo '{"id":1,"default_branch":"main","allow_squash_merge":true,"allow_rebase_merge":false,"allow_merge_commit":false,"delete_branch_on_merge":true,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "--check security audit: all enabled → no security drift" {
  write_profile_with_tag
  make_mock_gh_security_all_enabled
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.security.dependabot_alerts == "enabled"' >/dev/null
  echo "$out" | jq -e '.security.secret_scanning == "enabled"' >/dev/null
  echo "$out" | jq -e '.security.secret_scanning_push_protection == "enabled"' >/dev/null
  echo "$out" | jq -e '.security.code_scanning_default_setup == "enabled"' >/dev/null
  echo "$out" | jq -e '.security.drift | length == 0' >/dev/null
}

@test "--check security audit: all disabled → 4 warn drifts" {
  write_profile_with_tag
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets/*) echo '{"id":42,"name":"protect-tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}'; exit 0 ;;
        */rulesets) echo '[{"id":42,"name":"protect-tags"}]'; exit 0 ;;
        */vulnerability-alerts) echo "HTTP/2.0 404: Not Found" >&2; exit 1 ;;
        */code-scanning/default-setup) echo '{"state":"not-configured"}'; exit 0 ;;
        */repos/*/*) echo '{"security_and_analysis":{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.security.drift | length == 4' >/dev/null
  echo "$out" | jq -e '[.security.drift[].severity] | unique == ["warn"]' >/dev/null
  # All four field names are covered.
  for field in dependabot_alerts secret_scanning secret_scanning_push_protection code_scanning_default_setup; do
    echo "$out" | jq -e --arg f "$field" '[.security.drift[] | select(.field == $f)] | length == 1' >/dev/null
  done
}

@test "--check security audit: vulnerability-alerts transient failure → unknown (no false drift)" {
  # Earlier code mapped any non-zero exit from vulnerability-alerts
  # to "disabled" → false-positive warn drift on auth flicker /
  # rate-limit / network. The fix distinguishes 404 (real disabled,
  # stderr says "Not Found") from other failures (mark unknown).
  write_profile_with_tag
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
        # Simulate transient: 5xx server error, NOT 404.
        */vulnerability-alerts) echo "HTTP/2.0 502 Bad Gateway" >&2; exit 1 ;;
        */code-scanning/default-setup) echo '{"state":"configured"}'; exit 0 ;;
        */repos/*/*) echo '{"id":1,"default_branch":"main","allow_squash_merge":true,"allow_rebase_merge":false,"allow_merge_commit":false,"delete_branch_on_merge":true,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  # State should be "unknown" — we couldn't determine it.
  [ "$(echo "$out" | jq -r '.security.dependabot_alerts')" = "unknown" ]
  # And NO drift entry should be added — unknown isn't a finding.
  echo "$out" | jq -e '[.security.drift[] | select(.field == "dependabot_alerts")] | length == 0' >/dev/null
}

@test "--check security audit: code scanning 404 → not-applicable (no drift)" {
  # Private repos on plans without code scanning return 404 from the
  # default-setup endpoint. That should resolve to not-applicable and
  # NOT trigger a drift entry.
  write_profile_with_tag
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets/*) echo '{"id":42,"name":"protect-tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}'; exit 0 ;;
        */rulesets) echo '[{"id":42,"name":"protect-tags"}]'; exit 0 ;;
        */vulnerability-alerts) exit 0 ;;
        */code-scanning/default-setup) echo '{"message":"Not Found"}'; exit 0 ;;
        */repos/*/*) echo '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.security.code_scanning_default_setup == "not-applicable"' >/dev/null
  echo "$out" | jq -e '[.security.drift[] | select(.field == "code_scanning_default_setup")] | length == 0' >/dev/null
}

@test "--check security audit: repo metadata unreachable → security skipped" {
  # Mock returns empty body for the /repos/{o}/{r} call; section soft-skips.
  write_profile_with_tag
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets/*) echo '{"id":42,"name":"protect-tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}'; exit 0 ;;
        */rulesets) echo '[{"id":42,"name":"protect-tags"}]'; exit 0 ;;
        # Critical: repo meta returns nothing; this is the trigger.
        */repos/nyann/fake) echo ''; exit 1 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile with-tag --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.security.skipped == true' >/dev/null
  echo "$out" | jq -e '.security.reason == "repo-metadata-unreachable"' >/dev/null
  echo "$out" | jq -e '.summary.skipped_sections | index("security") != null' >/dev/null
}

# ---- --check CODEOWNERS-required gate -------------------------------------
# Three states the gate audit covers:
#   1. file-missing-but-required (critical) — profile demands the gate
#      but no CODEOWNERS file ships in the repo.
#   2. file-present-but-gate-off (warn) — file exists, profile demands
#      the gate, but branch protection has require_code_owner_reviews=false.
#   3. file-present-but-not-required-by-profile (warn) — informational:
#      a CODEOWNERS file exists but the profile doesn't require the gate.

write_profile_with_codeowners_required() {
  cat > "$UR/profiles/co-required.json" <<JSON
{
  "\$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "co-required",
  "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "github": {"enable_branch_protection": true, "require_code_owner_reviews": true},
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
JSON
}

@test "--check codeowners gate: profile requires gate but file missing → critical" {
  write_profile_with_codeowners_required
  make_mock_gh_no_protection
  out=$(bash "$SCRIPT" --profile co-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.codeowners_gate.file_present == false' >/dev/null
  echo "$out" | jq -e '.codeowners_gate.gate_required_in_profile == true' >/dev/null
  echo "$out" | jq -e '
    [.codeowners_gate.drift[] | select(.kind == "file-missing-but-required" and .severity == "critical")]
    | length == 1
  ' >/dev/null
}

@test "--check codeowners gate: file present + profile requires + branch gate off → warn drift" {
  write_profile_with_codeowners_required
  # Plant a CODEOWNERS file in the target repo at the canonical path.
  mkdir -p "$TARGET/.github"
  echo "* @org/team" > "$TARGET/.github/CODEOWNERS"
  # Mock that returns branch protection WITHOUT require_code_owner_reviews.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection)
          # Branch protection exists but require_code_owner_reviews=false.
          echo '{"required_pull_request_reviews":{"required_approving_review_count":1,"require_code_owner_reviews":false},"required_status_checks":null,"enforce_admins":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile co-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.codeowners_gate.file_present == true' >/dev/null
  echo "$out" | jq -e '
    [.codeowners_gate.drift[] | select(.kind == "file-present-but-gate-off" and .branch == "main" and .severity == "warn")]
    | length == 1
  ' >/dev/null
  # Cleanup the planted CODEOWNERS so other tests aren't affected.
  rm -f "$TARGET/.github/CODEOWNERS"
}

@test "--check codeowners gate: file present + profile silent → informational drift" {
  # protect-me profile has no require_code_owner_reviews. CODEOWNERS
  # file exists. Surface as informational (warn-severity) drift —
  # users who landed here unintentionally can flip the profile bit.
  mkdir -p "$TARGET/.github"
  echo "* @org/team" > "$TARGET/.github/CODEOWNERS"
  make_mock_gh_no_protection
  out=$(bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.codeowners_gate.file_present == true' >/dev/null
  echo "$out" | jq -e '.codeowners_gate.gate_required_in_profile == false' >/dev/null
  echo "$out" | jq -e '
    [.codeowners_gate.drift[] | select(.kind == "file-present-but-not-required-by-profile" and .severity == "warn")]
    | length == 1
  ' >/dev/null
  rm -f "$TARGET/.github/CODEOWNERS"
}

@test "--check codeowners gate: file present + profile requires + gate on → no drift" {
  write_profile_with_codeowners_required
  mkdir -p "$TARGET/.github"
  echo "* @org/team" > "$TARGET/.github/CODEOWNERS"
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection)
          # Branch protection with require_code_owner_reviews=true.
          echo '{"required_pull_request_reviews":{"required_approving_review_count":1,"require_code_owner_reviews":true},"required_status_checks":null,"enforce_admins":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile co-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.codeowners_gate.file_present == true' >/dev/null
  echo "$out" | jq -e '.codeowners_gate.drift | length == 0' >/dev/null
  echo "$out" | jq -e '.codeowners_gate.branches_with_gate == ["main"]' >/dev/null
  rm -f "$TARGET/.github/CODEOWNERS"
}

# ---- --check signing audit ------------------------------------------------
# Profile fields .github.require_signed_commits + .github.require_signed_tags
# enable per-branch required_signatures + local commit.gpgsign / tag.gpgsign
# checks. Drift severity: missing branch-side required_signatures = critical;
# local config gaps = warn (release.sh would still produce unsigned tags).

write_profile_with_signing() {
  cat > "$UR/profiles/sign-required.json" <<JSON
{
  "\$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "sign-required",
  "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "github": {
    "enable_branch_protection": true,
    "require_signed_commits": true,
    "require_signed_tags": true
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
JSON
}

# Mock that returns a branch with required_signatures.enabled=true.
make_mock_gh_signing_required() {
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection)
          echo '{"required_pull_request_reviews":{"required_approving_review_count":1,"require_code_owner_reviews":false},"required_signatures":{"enabled":true},"required_status_checks":null,"enforce_admins":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "--check signing: profile demands signed commits + branch enables required_signatures + local config on → no drift" {
  write_profile_with_signing
  make_mock_gh_signing_required
  # Set up local config that satisfies the audit.
  git -C "$TARGET" config commit.gpgsign true
  git -C "$TARGET" config tag.gpgsign true
  git -C "$TARGET" config user.signingkey ABCDEF1234567890
  out=$(bash "$SCRIPT" --profile sign-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.signing.commit_signing_required_in_profile == true' >/dev/null
  echo "$out" | jq -e '.signing.tag_signing_required_in_profile == true' >/dev/null
  echo "$out" | jq -e '.signing.branches[0].required_signatures_enabled == true' >/dev/null
  echo "$out" | jq -e '.signing.local_config.commit_gpgsign == true' >/dev/null
  echo "$out" | jq -e '.signing.local_config.tag_gpgsign == true' >/dev/null
  echo "$out" | jq -e '.signing.local_config.user_signingkey_present == true' >/dev/null
  echo "$out" | jq -e '.signing.drift | length == 0' >/dev/null
}

@test "--check signing: profile demands signing but local config off → 3 warn drifts" {
  write_profile_with_signing
  make_mock_gh_signing_required
  # Local config is unset (default).
  out=$(bash "$SCRIPT" --profile sign-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  # Expect 3 warns: commit.gpgsign off, tag.gpgsign off, user.signingkey unset.
  echo "$out" | jq -e '
    [.signing.drift[] | select(.severity == "warn")] | length == 3
  ' >/dev/null
}

@test "--check signing: profile demands signed commits + branch missing required_signatures → critical drift" {
  write_profile_with_signing
  # Mock that returns a branch protection WITHOUT required_signatures.
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection)
          echo '{"required_pull_request_reviews":{"required_approving_review_count":1,"require_code_owner_reviews":false},"required_status_checks":null,"enforce_admins":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'
          exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile sign-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  # required_signatures_enabled drift is critical (server side).
  echo "$out" | jq -e '
    [.signing.drift[] | select(.field == "required_signatures_enabled" and .severity == "critical")] | length == 1
  ' >/dev/null
}

@test "--check signing: profile silent → signing section emitted but drift empty" {
  # protect-me has no signing fields. Section still appears (schema requires
  # it) but with all_required=false and no drift entries.
  make_mock_gh_signing_required
  out=$(bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.signing.commit_signing_required_in_profile == false' >/dev/null
  echo "$out" | jq -e '.signing.tag_signing_required_in_profile == false' >/dev/null
  echo "$out" | jq -e '.signing.drift | length == 0' >/dev/null
}

# ---- --check repo-settings audit ------------------------------------------
# Profile fields .github.{allow_squash_merge, allow_rebase_merge,
# allow_merge_commit, delete_branch_on_merge} opt sub-checks in. The
# default-branch check is automatic — profile.branching.base_branches[0]
# is the expected value. Mismatch on default branch is critical (PRs
# would target the wrong base); mismatch on the others is warn.

write_profile_with_repo_settings() {
  cat > "$UR/profiles/rs-required.json" <<JSON
{
  "\$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "rs-required",
  "schemaVersion": 1,
  "stack": {"primary_language": "typescript"},
  "branching": {"strategy": "github-flow", "base_branches": ["main"]},
  "hooks": {"pre_commit": [], "commit_msg": [], "pre_push": []},
  "extras": {},
  "conventions": {"commit_format": "conventional-commits"},
  "github": {
    "enable_branch_protection": true,
    "allow_squash_merge": true,
    "allow_rebase_merge": false,
    "allow_merge_commit": false,
    "delete_branch_on_merge": true
  },
  "documentation": {"scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router"}
}
JSON
}

@test "--check repo settings: actual matches profile → no drift" {
  write_profile_with_repo_settings
  make_mock_gh_security_all_enabled
  out=$(bash "$SCRIPT" --profile rs-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.repo_settings.default_branch.matches == true' >/dev/null
  echo "$out" | jq -e '.repo_settings.merge_buttons.squash.expected == true' >/dev/null
  echo "$out" | jq -e '.repo_settings.merge_buttons.squash.actual == true' >/dev/null
  echo "$out" | jq -e '.repo_settings.delete_branch_on_merge.actual == true' >/dev/null
  echo "$out" | jq -e '.repo_settings.drift | length == 0' >/dev/null
}

@test "--check repo settings: profile silent on merge buttons → no drift on those" {
  # protect-me has no repo_settings fields. Section still emitted; merge
  # button expecteds=null; no drift entries.
  make_mock_gh_security_all_enabled
  out=$(bash "$SCRIPT" --profile protect-me --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.repo_settings.merge_buttons.squash.expected == null' >/dev/null
  echo "$out" | jq -e '.repo_settings.merge_buttons.rebase.expected == null' >/dev/null
  echo "$out" | jq -e '.repo_settings.merge_buttons.commit.expected == null' >/dev/null
  echo "$out" | jq -e '.repo_settings.delete_branch_on_merge.expected == null' >/dev/null
  # No drift since profile expressed no expectation.
  echo "$out" | jq -e '[.repo_settings.drift[] | select(.field | startswith("allow_"))] | length == 0' >/dev/null
}

@test "--check repo settings: default_branch mismatch → critical drift" {
  # Profile expects main; mock returns master.
  write_profile_with_repo_settings
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
        */vulnerability-alerts) exit 0 ;;
        */code-scanning/default-setup) echo '{"state":"configured"}'; exit 0 ;;
        */repos/*/*) echo '{"id":1,"default_branch":"master","allow_squash_merge":true,"allow_rebase_merge":false,"allow_merge_commit":false,"delete_branch_on_merge":true,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile rs-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  echo "$out" | jq -e '.repo_settings.default_branch.matches == false' >/dev/null
  echo "$out" | jq -e '
    [.repo_settings.drift[] | select(.field == "default_branch" and .severity == "critical")] | length == 1
  ' >/dev/null
}

@test "--check repo settings: merge buttons disagree → warn drift" {
  # Profile says squash-only (allow_squash=true, others=false). Actual
  # has all three enabled.
  write_profile_with_repo_settings
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  api)
    for a in "$@"; do
      case "$a" in
        */branches/*/protection) echo '{"message":"Branch not protected"}'; exit 0 ;;
        */rulesets) echo '[]'; exit 0 ;;
        */vulnerability-alerts) exit 0 ;;
        */code-scanning/default-setup) echo '{"state":"configured"}'; exit 0 ;;
        */repos/*/*) echo '{"id":1,"default_branch":"main","allow_squash_merge":true,"allow_rebase_merge":true,"allow_merge_commit":true,"delete_branch_on_merge":false,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; exit 0 ;;
      esac
    done
    echo '{}'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  out=$(bash "$SCRIPT" --profile rs-required --target "$TARGET" --user-root "$UR" \
    --owner nyann --repo fake --gh "$TMP/mock/gh" --check 2>/dev/null)
  # 3 warns: rebase, commit, delete-on-merge all disagree.
  echo "$out" | jq -e '
    [.repo_settings.drift[] | select(.severity == "warn")] | length == 3
  ' >/dev/null
}

@test "--check skip when gh missing emits ProtectionAudit-shaped skip JSON" {
  # When gh is missing the audit path returns a ProtectionAudit-shaped
  # skip so doctor can branch on the same shape regardless of gh
  # availability. The default path returns a different skip shape.
  empty_bin="$TMP/empty-bin"
  mkdir -p "$empty_bin"
  for exe in jq git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum python3 bash; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$empty_bin/$exe" 2>/dev/null || true
  done
  # Parse stdout only (warn goes to stderr) so jq doesn't choke on the
  # mixed bats-run output buffer.
  out=$(env -i HOME="$HOME" PATH="$empty_bin" bash "$SCRIPT" --profile protect-me \
    --target "$TARGET" --user-root "$UR" --check 2>/dev/null)
  # ProtectionAudit-shaped skip: branches=[], skipped sections listed.
  echo "$out" | jq -e '.branches == []' >/dev/null
  echo "$out" | jq -e '.tag_protection.skipped == true' >/dev/null
  echo "$out" | jq -e '.security.skipped == true' >/dev/null
  echo "$out" | jq -e '.summary.skipped_sections | length == 6' >/dev/null
}
