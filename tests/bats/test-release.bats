#!/usr/bin/env bats
# bin/release.sh — conventional-changelog flow, manual tagging, dry-run,
# edge cases.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RELEASE="${REPO_ROOT}/bin/release.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

make_repo_with_cc_history() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: initial"
    git -c user.email=t@t -c user.name=t tag v0.1.0
    # Commits since tag.
    echo "a" > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat(api): add endpoint A"
    echo "b" > b.txt
    git -c user.email=t@t -c user.name=t add b.txt
    git -c user.email=t@t -c user.name=t commit -q -m "fix(db): correct migration order"
    echo "c" > c.txt
    git -c user.email=t@t -c user.name=t add c.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat(api)!: drop legacy route"
    echo "d" > d.txt
    git -c user.email=t@t -c user.name=t add d.txt
    git -c user.email=t@t -c user.name=t commit -q -m "docs: expand README"
  )
  echo "$repo"
}

@test "missing --version dies" {
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--version"
}

@test "invalid semver dies" {
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo" --version "1.2"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "semver"
}

@test "conventional-changelog dry-run renders grouped block" {
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --dry-run 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')"   = "released" ]
  [ "$(echo "$out" | jq -r '.tag')"      = "v0.2.0" ]
  [ "$(echo "$out" | jq -r '.from')"     = "v0.1.0" ]
  [ "$(echo "$out" | jq '.commits | length')" -eq 4 ]
  # Changelog contents — stable ordering.
  changelog=$(echo "$out" | jq -r '.changelog')
  echo "$changelog" | grep -F -e "## [0.2.0]"
  echo "$changelog" | grep -F -e "Breaking"
  echo "$changelog" | grep -F -e "add endpoint A"
  echo "$changelog" | grep -F -e "correct migration order"
  echo "$changelog" | grep -F -e "expand README"
}

@test "conventional-changelog dry-run does not mutate repo" {
  repo=$(make_repo_with_cc_history)
  before=$(git -C "$repo" rev-parse HEAD)
  tags_before=$(git -C "$repo" tag | wc -l | tr -d ' ')
  bash "$RELEASE" --target "$repo" --version 0.2.0 --dry-run >/dev/null 2>&1
  after=$(git -C "$repo" rev-parse HEAD)
  tags_after=$(git -C "$repo" tag | wc -l | tr -d ' ')
  [ "$before" = "$after" ]
  [ "$tags_before" = "$tags_after" ]
}

@test "first release includes the root commit instead of false-noop" {
  repo="$TMP/root-release"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: seed release"
  )

  out=$(bash "$RELEASE" --target "$repo" --version 0.1.0 --dry-run 2>/dev/null)

  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ "$(echo "$out" | jq -r '.commits | length')" = "1" ]
  echo "$out" | jq -r '.changelog' | grep -F "seed release"
}

@test "conventional-changelog dry-run JSON validates against the schema" {
  # The dry-run path emits `dry_run:true` and `next_steps:[]` so the
  # ReleaseSuccess shape can validate without exception. Easy to drop
  # one of those by accident; lock it.
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --dry-run 2>/dev/null)
  out_file="$TMP/release-dry-run.json"
  echo "$out" > "$out_file"
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/release-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/release-result.schema.json" "$out_file"
  fi
}

@test "conventional-changelog real run writes CHANGELOG + commit + tag" {
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ -f "$repo/CHANGELOG.md" ]
  grep -F "## [0.2.0]" "$repo/CHANGELOG.md"
  # Release commit exists on HEAD.
  git -C "$repo" log -1 --pretty=%s | grep -F "chore(release): v0.2.0"
  # Tag exists.
  git -C "$repo" rev-parse --verify refs/tags/v0.2.0 >/dev/null
}

@test "conventional-changelog refuses real run without --yes" {
  # Regression: release.sh used to overwrite CHANGELOG.md on any non-dry
  # invocation, bypassing preview-before-mutate. Now requires --yes;
  # without it, prints the rendered block and exits 2 so the caller is
  # forced to confirm first.
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo" --version 0.2.0
  [ "$status" -eq 2 ]
  echo "$output" | grep -F "preview-before-mutate"
  echo "$output" | grep -F "Re-run with --yes"
  # No mutation happened.
  [ ! -f "$repo/CHANGELOG.md" ]
  ! git -C "$repo" rev-parse --verify refs/tags/v0.2.0 >/dev/null 2>&1
}

@test "manual strategy does NOT require --yes (no CHANGELOG write)" {
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual
  [ "$status" -eq 0 ]
}

@test "conventional-changelog prepends to existing CHANGELOG (doesn't clobber)" {
  repo=$(make_repo_with_cc_history)
  cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [0.1.0] — 2026-04-01

Initial release.
EOF
  git -C "$repo" -c user.email=t@t -c user.name=t add CHANGELOG.md
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "docs: seed changelog"
  bash "$RELEASE" --target "$repo" --version 0.2.0 --yes >/dev/null 2>&1
  # New block is above the old one.
  first_v=$(grep -E '^## \[' "$repo/CHANGELOG.md" | head -n1)
  echo "$first_v" | grep -F -e "0.2.0"
  grep -F -e "0.1.0" "$repo/CHANGELOG.md"
  grep -F -e "Initial release" "$repo/CHANGELOG.md"
}

@test "manual strategy only creates the tag (no changelog, no commit)" {
  repo=$(make_repo_with_cc_history)
  before=$(git -C "$repo" rev-parse HEAD)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ ! -f "$repo/CHANGELOG.md" ]
  after=$(git -C "$repo" rev-parse HEAD)
  [ "$before" = "$after" ]
  git -C "$repo" rev-parse --verify refs/tags/v0.2.0 >/dev/null
}

@test "changesets strategy soft-skips with guidance" {
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy changesets 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "skipped" ]
  echo "$out" | jq -r '.reason' | grep -F -e "changesets"
}

@test "release-please strategy soft-skips with guidance" {
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy release-please 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "skipped" ]
  echo "$out" | jq -r '.reason' | grep -F -e "release-please"
}

@test "existing tag dies" {
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo" --version 0.1.0
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "already exists"
}

@test "no commits since last tag → noop" {
  repo=$(make_repo_with_cc_history)
  # Tag current HEAD so there are zero commits in range.
  git -C "$repo" tag v0.1.99
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --from v0.1.99 2>/dev/null)
  [ "$(echo "$out" | jq -r '.status')" = "noop" ]
}

@test "dirty tree refuses (non-dry-run)" {
  repo=$(make_repo_with_cc_history)
  echo "dirty" > "$repo/dirty.txt"
  git -C "$repo" -c user.email=t@t -c user.name=t add dirty.txt
  run bash "$RELEASE" --target "$repo" --version 0.2.0
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "uncommitted"
}

@test "--tag-prefix supports namespaced tags" {
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --tag-prefix "api-v" --strategy manual 2>/dev/null)
  [ "$(echo "$out" | jq -r '.tag')" = "api-v0.2.0" ]
  git -C "$repo" rev-parse --verify refs/tags/api-v0.2.0 >/dev/null
}

# ---- push failure: recovery hints + non-zero exit --------------------------
# When --push is requested but the remote is unreachable / unauthenticated /
# protected, release.sh used to print a warning and still exit 0 with
# pushed:false. CI / skill-layer wrappers couldn't tell the half-state from
# a clean release. Now: exit 3, plus a next_steps[] array with copy-paste-
# ready recovery commands.

@test "push to nonexistent remote returns exit 3 + next_steps" {
  repo=$(make_repo_with_cc_history)
  # Add an unreachable origin so the push fails deterministically.
  git -C "$repo" remote add origin "file:///definitely/not/a/real/path-$$"

  # Capture stdout + exit. release.sh prints stderr warnings; we only
  # inspect the JSON via stdout.
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push 2>/dev/null) && rc=0 || rc=$?

  [ "$rc" -eq 3 ]
  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ "$(echo "$out" | jq -r '.pushed')" = "false" ]
  # Both the tag-push and (since strategy=conventional-changelog) the
  # branch-push are recovery candidates, so next_steps has at least 1.
  n=$(echo "$out" | jq '.next_steps | length')
  [ "$n" -ge 1 ]
  echo "$out" | jq -r '.next_steps[]' | grep -Fq "git push origin v0.2.0"
}

@test "no --push flag still exits 0 (pushed:false is expected)" {
  repo=$(make_repo_with_cc_history)
  # No remote needed; --push wasn't requested.
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.pushed')" = "false" ]
  # next_steps is empty when no push was attempted.
  [ "$(echo "$out" | jq '.next_steps | length')" = "0" ]
}

# ---- pre-release tagging --------------------------------------------------
# A SemVer suffix on --version (e.g. 1.0.0-rc.1) flips the prerelease
# flag in the output. The CHANGELOG is NOT touched and no release
# commit is created — only the tag is added so `gh release create
# --prerelease` consumers can pick it up. The [Unreleased] section
# stays queued for the eventual stable release.

@test "prerelease real run does NOT modify CHANGELOG and creates only the tag" {
  repo=$(make_repo_with_cc_history)
  # Capture the CHANGELOG state + commit SHA before the cut.
  changelog_before=""
  [ -f "$repo/CHANGELOG.md" ] && changelog_before=$(cat "$repo/CHANGELOG.md")
  head_before=$(git -C "$repo" rev-parse HEAD)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0-rc.1 --yes 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  # CHANGELOG must be byte-identical (no prepend, no fresh creation).
  changelog_after=""
  [ -f "$repo/CHANGELOG.md" ] && changelog_after=$(cat "$repo/CHANGELOG.md")
  [ "$changelog_before" = "$changelog_after" ]
  # HEAD must match (no release commit added).
  head_after=$(git -C "$repo" rev-parse HEAD)
  [ "$head_before" = "$head_after" ]
  # Output flags it as prerelease.
  [ "$(echo "$out" | jq -r '.prerelease')" = "true" ]
  [ "$(echo "$out" | jq -r '.tag')" = "v0.2.0-rc.1" ]
  # Tag exists.
  git -C "$repo" rev-parse v0.2.0-rc.1 >/dev/null
}

@test "stable real run sets prerelease:false and DOES modify CHANGELOG" {
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.prerelease')" = "false" ]
  # CHANGELOG was modified (the assertion that's symmetric to the
  # prerelease test above).
  grep -F -e "## [0.2.0]" "$repo/CHANGELOG.md"
}

@test "prerelease dry-run JSON validates against the schema (prerelease present)" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  repo=$(make_repo_with_cc_history)
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0-rc.1 --dry-run 2>/dev/null)
  out_file="$TMP/release-prerelease.json"
  echo "$out" > "$out_file"
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/release-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/release-result.schema.json" "$out_file"
  fi
  [ "$(echo "$out" | jq -r '.prerelease')" = "true" ]
  [ "$(echo "$out" | jq -r '.dry_run')" = "true" ]
}

# ---- --wait-for-checks ----------------------------------------------------
# When --wait-for-checks is set, release.sh must:
#  - Resolve the PR for HEAD via `gh pr list --search <SHA>`.
#  - Invoke wait-for-pr-checks.sh and gate the tag step on the outcome.
#  - Hard-fail with exit 2 on CI fail / timeout / unreachable gh
#    (the user opted into gating, so silent proceed defeats the purpose).
#  - Skip the gate on --dry-run regardless of the flag (no network burn).

# Mock gh that handles auth + pr list (PR resolution) + pr checks (wait-for-pr-checks).
# $1 = pr_num         (number to return, or literal "none" for "no PR found")
# $2 = checks_outcome (success | failure | timeout-empty)
make_mock_gh_release() {
  local pr_num="${1:-42}"
  local checks_outcome="${2:-success}"
  local list_body
  if [[ "$pr_num" == "none" ]]; then
    list_body='[]'
  else
    list_body="[{\"number\":${pr_num}}]"
  fi
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
case "\$1" in
  auth) exit 0 ;;
  pr)
    case "\$2" in
      list) echo '${list_body}'; exit 0 ;;
      checks)
        case "${checks_outcome}" in
          success) echo '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]' ;;
          failure) echo '[{"name":"test","status":"completed","conclusion":"failure","workflow":"ci.yml"}]' ;;
          timeout-empty) echo '[{"name":"slow","status":"in_progress","conclusion":"","workflow":"ci.yml"}]' ;;
          no-checks) echo '[]' ;;
        esac
        exit 0 ;;
      view)   echo '{"number":'"${pr_num:-0}"'}'; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
}

@test "--wait-for-checks: green CI → tag created, ci_gate:{outcome:pass} in output" {
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release 42 success
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 10 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.status')" = "released" ]
  [ "$(echo "$out" | jq -r '.ci_gate.outcome')" = "pass" ]
  [ "$(echo "$out" | jq -r '.ci_gate.pr_number')" = "42" ]
  git -C "$repo" rev-parse v0.2.0 >/dev/null
}

@test "--wait-for-checks: failing CI → exit 2, no tag created" {
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release 42 failure
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 5 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "PR #42 CI failed"
  ! git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "--wait-for-checks: timeout → exit 2, no tag created, hint to bump timeout" {
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release 42 timeout-empty
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 2 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "did not settle within"
  echo "$output" | grep -F -e "wait-for-checks-timeout"
  ! git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "--wait-for-checks: gh missing → die hard (do NOT silently proceed)" {
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --gh "/tmp/definitely-not-gh-$$"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "gh binary not found"
  ! git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "--wait-for-checks: gh unauth → die hard" {
  repo=$(make_repo_with_cc_history)
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<'SH'
#!/bin/sh
case "$1" in auth) exit 1 ;; *) exit 0 ;; esac
SH
  chmod +x "$TMP/mock/gh"
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --gh "$TMP/mock/gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "not authenticated"
}

@test "--wait-for-checks: no PR found for HEAD without --allow-no-pr → die hard" {
  # Squash/rebase release flows where the release commit's SHA doesn't
  # map back to the PR must hard-fail rather than silently bypassing
  # the gate. Opt back in via --allow-no-pr for first-cut or
  # local-only releases.
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release "none" success  # sentinel → gh pr list returns []
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 5 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "no PR found for HEAD"
  echo "$output" | grep -F -e "--allow-no-pr"
  ! git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "--wait-for-checks --allow-no-pr: no PR found → warn but proceed, ci_gate:{outcome:no-pr-found}" {
  # Opt-in path for legitimate no-PR releases (first cut, local-only).
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release "none" success
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --allow-no-pr \
    --wait-for-checks-timeout 5 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.ci_gate.outcome')" = "no-pr-found" ]
  echo "$out" | jq -e '.ci_gate | has("pr_number") | not' >/dev/null
  git -C "$repo" rev-parse v0.2.0 >/dev/null
}

@test "--wait-for-checks: no-checks without --allow-no-checks → die hard" {
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release 42 no-checks
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 5 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "no checks attached"
  echo "$output" | grep -F -e "--allow-no-checks"
  ! git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "--wait-for-checks --allow-no-checks: no-checks → warn but proceed, ci_gate:{outcome:no-checks}" {
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release 42 no-checks
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --allow-no-checks \
    --wait-for-checks-timeout 5 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.ci_gate.outcome')" = "no-checks" ]
  [ "$(echo "$out" | jq -r '.ci_gate.pr_number')" = "42" ]
  git -C "$repo" rev-parse v0.2.0 >/dev/null
}

@test "--wait-for-checks: --dry-run skips the gate (no ci_gate in output)" {
  repo=$(make_repo_with_cc_history)
  # Mock that would FAIL — but dry-run must not invoke it.
  make_mock_gh_release 42 failure
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --dry-run \
    --wait-for-checks --gh "$TMP/mock/gh" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r '.dry_run')" = "true" ]
  echo "$out" | jq -e 'has("ci_gate") | not' >/dev/null
}

@test "--wait-for-checks: bad timeout dies before any network" {
  repo=$(make_repo_with_cc_history)
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 0
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "must be a positive integer"
}

@test "--wait-for-checks: real-run output validates against release-result schema (with ci_gate)" {
  if ! command -v check-jsonschema >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    skip "check-jsonschema not available"
  fi
  repo=$(make_repo_with_cc_history)
  make_mock_gh_release 42 success
  out_file="$TMP/release-with-gate.json"
  bash "$RELEASE" --target "$repo" --version 0.2.0 --strategy manual \
    --wait-for-checks --wait-for-checks-timeout 5 --wait-for-checks-interval 1 \
    --gh "$TMP/mock/gh" > "$out_file" 2>/dev/null
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "${REPO_ROOT}/schemas/release-result.schema.json" "$out_file"
  else
    uvx check-jsonschema --schemafile "${REPO_ROOT}/schemas/release-result.schema.json" "$out_file"
  fi
}
