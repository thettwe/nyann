#!/usr/bin/env bash
# gh-integration.sh — manage GitHub branch protection per a profile's
# branching strategy. Two modes:
#
# Usage:
#   gh-integration.sh --target <repo> --profile <name>
#                     [--owner <owner> --repo <repo>]
#                     [--gh <path>]            # for testing with a mock gh
#                     [--check]                 # read-only audit; no writes
#
# Behavior:
#   1. Require `gh` on PATH (or --gh <path>) AND `gh auth status` succeeds.
#      If either fails, exit 0 with a structured skip JSON on stdout —
#      never fatal, never prompts for credentials.
#   2. Load the profile (user > starter) for the branching strategy.
#   3. Determine owner/repo from git remote (or --owner/--repo).
#   4a. (default) Apply protection via `gh api PUT
#       /repos/<owner>/<repo>/branches/<branch>/protection` with the
#       matching rule set. Reads current protection first; if the remote
#       is already stricter (more reviews required, etc.), leaves it and
#       logs a note.
#   4b. (--check) Read-only audit. Reads current protection for every
#       strategy-declared branch, plus tag protection (Rulesets API),
#       CODEOWNERS gate state, and repo security settings (Dependabot,
#       secret scanning, push protection, code scanning). Emits a
#       ProtectionAudit JSON (schemas/protection-audit.schema.json).
#       The doctor probe consumes this output.
#
# Output:
#   * default: JSON summary describing what was applied / skipped.
#   * --check: ProtectionAudit JSON (see schemas/protection-audit.schema.json).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_name=""
owner=""
repo=""
gh_bin="gh"
user_root=""
check_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --profile)      profile_name="${2:-}"; shift 2 ;;
    --profile=*)    profile_name="${1#--profile=}"; shift ;;
    --owner)        owner="${2:-}"; shift 2 ;;
    --owner=*)      owner="${1#--owner=}"; shift ;;
    --repo)         repo="${2:-}"; shift 2 ;;
    --repo=*)       repo="${1#--repo=}"; shift ;;
    --gh)           gh_bin="${2:-}"; shift 2 ;;
    --gh=*)         gh_bin="${1#--gh=}"; shift ;;
    --user-root)    user_root="${2:-}"; shift 2 ;;
    --user-root=*)  user_root="${1#--user-root=}"; shift ;;
    --check)        check_only=true; shift ;;
    -h|--help)      sed -n '3,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

user_root="${user_root:-${HOME}/.claude/nyann}"

skip() {
  # $1=reason
  if $check_only; then
    # In --check mode emit a ProtectionAudit-shaped skip so the doctor
    # probe and any other consumer can branch on the same shape
    # whether gh is reachable or not.
    jq -n --arg target "$target" --arg owner "$owner" --arg repo "$repo" --arg reason "$1" '{
      target: $target,
      owner: $owner,
      repo: $repo,
      branches: [],
      tag_protection:  { skipped: true, reason: $reason },
      codeowners_gate: { file_present: false, gate_required_in_profile: false, branches_with_gate: [], drift: [] },
      security:        { skipped: true, reason: $reason },
      signing: {
        commit_signing_required_in_profile: false,
        tag_signing_required_in_profile:    false,
        branches: [],
        local_config: { commit_gpgsign: false, tag_gpgsign: false, user_signingkey_present: false },
        drift: []
      },
      repo_settings: { skipped: true, reason: $reason },
      summary: { total_drift: 0, critical: 0, warn: 0, skipped_sections: ["branches", "tag_protection", "codeowners_gate", "security", "signing", "repo_settings"] }
    }'
  else
    jq -n --arg reason "$1" '{skipped:"gh-integration", reason:$reason}'
  fi
  exit 0
}

# --- phase 1: validate required inputs ----------------------------------------

[[ -n "$profile_name" ]] || nyann::die "--profile is required"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

# --- phase 2: guard gh availability ------------------------------------------

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  nyann::warn "gh not found on PATH; skipping GitHub integration"
  skip "gh-not-installed"
fi

if ! "$gh_bin" auth status >/dev/null 2>&1; then
  nyann::warn "gh is installed but not authenticated; skipping GitHub integration"
  skip "gh-not-authenticated"
fi

# --- phase 3: load profile ---------------------------------------------------

tmp_profile=$(mktemp -t nyann-gh-profile.XXXXXX)
load_err=$(mktemp -t nyann-gh-load.XXXXXX)
apply_err=$(mktemp -t nyann-gh-apply.XXXXXX)
trap 'rm -f "$tmp_profile" "$load_err" "$apply_err"' EXIT
"${_script_dir}/load-profile.sh" "$profile_name" --user-root "$user_root" > "$tmp_profile" 2>"$load_err" || {
  cat "$load_err" >&2; rm -f "$tmp_profile"; exit 2
}

strategy=$(jq -r '.branching.strategy' "$tmp_profile")
# .github.enable_branch_protection: explicit false wins. //true only fires on
# null/missing — `false // true` would incorrectly coerce.
enable=$(jq -r 'if .github.enable_branch_protection == false then "false" else "true" end' "$tmp_profile")
required_reviews=$(jq -r '.github.require_pr_reviews // 1' "$tmp_profile")
required_checks_csv=$(jq -r '.github.require_status_checks // [] | join(",")' "$tmp_profile")
require_code_owner_reviews=$(jq -r '.github.require_code_owner_reviews // false' "$tmp_profile")
# shellcheck disable=SC2034 # consumed by the tag-protection section in --check.
tag_protection_pattern=$(jq -r '.github.tag_protection_pattern // ""' "$tmp_profile")
require_signed_commits=$(jq -r '.github.require_signed_commits // false' "$tmp_profile")
require_signed_tags=$(jq -r '.github.require_signed_tags // false' "$tmp_profile")
# Repo-settings audit fields (repo-config). `null` = profile silent
# on that button; the audit treats it as "no opinion" and emits no drift.
allow_squash_merge_expected=$(jq -r 'if .github.allow_squash_merge == null then "null" else (.github.allow_squash_merge|tostring) end' "$tmp_profile")
allow_rebase_merge_expected=$(jq -r 'if .github.allow_rebase_merge == null then "null" else (.github.allow_rebase_merge|tostring) end' "$tmp_profile")
allow_merge_commit_expected=$(jq -r 'if .github.allow_merge_commit == null then "null" else (.github.allow_merge_commit|tostring) end' "$tmp_profile")
delete_branch_on_merge_expected=$(jq -r 'if .github.delete_branch_on_merge == null then "null" else (.github.delete_branch_on_merge|tostring) end' "$tmp_profile")
# Default-branch expectation is the first entry in branching.base_branches.
default_branch_expected=$(jq -r '.branching.base_branches[0] // "main"' "$tmp_profile")
rm -f "$tmp_profile"

if [[ "$enable" != "true" ]] && ! $check_only; then
  # In --check mode we still want to report the absence of protection,
  # so don't skip out — let the audit run. The apply path bails since
  # the user explicitly opted out.
  skip "profile-disabled-branch-protection"
fi

# --- phase 3: resolve owner/repo ---------------------------------------------

if [[ -z "$owner" || -z "$repo" ]]; then
  remote_url=$(git -C "$target" remote get-url origin 2>/dev/null || echo "")
  # Accept either git@github.com:owner/repo.git or https://github.com/owner/repo(.git)
  if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    owner="${owner:-${BASH_REMATCH[1]}}"
    repo="${repo:-${BASH_REMATCH[2]}}"
  fi
fi
[[ -n "$owner" && -n "$repo" ]] || { nyann::warn "could not determine owner/repo"; skip "unknown-repo"; }

# The regex above accepts `[^/]+` for owner and `[^/.]+` for repo,
# letting `..` through. Values flow into `gh api
# "/repos/${owner}/${repo}/branches/..."` — authenticated `gh` could
# be steered to arbitrary GitHub API endpoints. Hard-enforce a
# conservative allowlist.
if ! [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || [[ "$owner" == *..* ]]; then
  nyann::warn "owner rejected as unsafe: $owner"
  skip "invalid-owner"
fi
if ! [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || [[ "$repo" == *..* ]]; then
  nyann::warn "repo rejected as unsafe: $repo"
  skip "invalid-repo"
fi

# --- shared helpers (used by both --check and --apply) ----------------------

branches_for_strategy() {
  case "$strategy" in
    github-flow) echo "main" ;;
    gitflow)     printf '%s\n' main develop ;;
    trunk-based) echo "main" ;;
    *)           echo "main" ;;
  esac
}

# Locate a CODEOWNERS file at any conventional path. Returns the path
# (relative to target) on stdout, empty string when absent. Used by
# the --check codeowners_gate section.
codeowners_path() {
  for p in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
    [[ -f "$target/$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# --- phase 4a: --check (read-only audit) ------------------------------------
# Emits a ProtectionAudit JSON conforming to
# schemas/protection-audit.schema.json. Doctor consumes this; no
# writes happen on this path.

if $check_only; then
  branches_arr='[]'
  total_drift=0
  total_critical=0
  total_warn=0

  # --- per-branch protection drift ---
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    expected=$(jq -n \
      --argjson rr "$required_reviews" \
      --arg checks_csv "$required_checks_csv" \
      --argjson co "$([[ "$require_code_owner_reviews" == "true" ]] && echo true || echo false)" \
      '{
        required_reviews: $rr,
        required_checks: ($checks_csv | if . == "" then [] else split(",") end),
        require_code_owner_reviews: $co,
        enforce_admins: true,
        allow_force_pushes: false,
        allow_deletions: false
      }')

    raw=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/branches/${branch}/protection" 2>/dev/null || echo '{}')
    # 404 / missing protection → actual=null; otherwise normalise.
    if [[ -z "$raw" ]] || [[ "$(jq -r 'type' <<<"$raw")" != "object" ]] || \
       [[ "$(jq -r '. | length' <<<"$raw")" == "0" ]] || \
       [[ "$(jq -r '.message // empty' <<<"$raw")" == "Branch not protected" ]]; then
      actual='null'
    else
      actual=$(jq '{
        required_reviews:           (.required_pull_request_reviews.required_approving_review_count // 0),
        required_checks:            (.required_status_checks.contexts // []),
        require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
        enforce_admins:             (.enforce_admins.enabled // false),
        allow_force_pushes:         (.allow_force_pushes.enabled // false),
        allow_deletions:            (.allow_deletions.enabled // false)
      }' <<<"$raw")
    fi

    # Build per-field drift array.
    drift='[]'
    if [[ "$actual" == "null" ]]; then
      drift=$(jq -n --argjson e "$expected" '[
        {field: "branch_protection_present", expected: true, actual: false, severity: "critical"}
      ]')
    else
      # Critical: missing review requirement, missing required checks,
      # admins not enforced, force-push allowed, deletions allowed.
      # Warn: review count below profile, status-check set narrower than profile,
      # codeowner gate off when profile says on.
      # jq quirk: `not` is a filter, not a prefix operator. Use
      # `($expr | not)` for negation. The earlier `(not $foo)` form
      # is a syntax error.
      drift=$(jq -n --argjson e "$expected" --argjson a "$actual" '
        [
          (if $a.required_reviews          < $e.required_reviews          then {field:"required_reviews",          expected:$e.required_reviews,          actual:$a.required_reviews,          severity:(if $e.required_reviews>0 and $a.required_reviews==0 then "critical" else "warn" end)} else empty end),
          (if (($e.required_checks - $a.required_checks) | length) > 0    then {field:"required_checks",           expected:$e.required_checks,           actual:$a.required_checks,           severity:"warn"}     else empty end),
          (if $e.require_code_owner_reviews and ($a.require_code_owner_reviews | not) then {field:"require_code_owner_reviews", expected:true, actual:$a.require_code_owner_reviews, severity:"warn"}     else empty end),
          (if $e.enforce_admins      and ($a.enforce_admins | not)        then {field:"enforce_admins",            expected:true,                          actual:$a.enforce_admins,            severity:"critical"} else empty end),
          (if $a.allow_force_pushes  and ($e.allow_force_pushes | not)    then {field:"allow_force_pushes",        expected:false,                         actual:true,                         severity:"critical"} else empty end),
          (if $a.allow_deletions     and ($e.allow_deletions | not)       then {field:"allow_deletions",           expected:false,                         actual:true,                         severity:"critical"} else empty end)
        ]
      ')
    fi
    branch_drift_count=$(jq 'length' <<<"$drift")
    crit=$(jq '[.[] | select(.severity == "critical")] | length' <<<"$drift")
    warn=$(jq '[.[] | select(.severity == "warn")] | length' <<<"$drift")
    total_drift=$((total_drift + branch_drift_count))
    total_critical=$((total_critical + crit))
    total_warn=$((total_warn + warn))

    branches_arr=$(jq --arg name "$branch" --argjson e "$expected" --argjson a "$actual" --argjson d "$drift" \
      '. + [{name:$name, expected:$e, actual:$a, drift:$d}]' <<<"$branches_arr")
  done < <(branches_for_strategy)

  # --- CODEOWNERS gate ---
  if codeowners_path >/dev/null; then file_present=true; else file_present=false; fi
  branches_with_gate=$(jq -r '[.[] | select(.actual != null and .actual.require_code_owner_reviews) | .name]' <<<"$branches_arr")
  co_drift='[]'
  if $file_present && [[ "$require_code_owner_reviews" != "true" ]]; then
    # CODEOWNERS exists but profile doesn't require it — informational.
    co_drift=$(jq -n '[{kind:"file-present-but-not-required-by-profile", branch:"*", severity:"warn"}]')
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  if ! $file_present && [[ "$require_code_owner_reviews" == "true" ]]; then
    # Profile requires the gate but the file is missing — high-impact.
    co_drift=$(jq -n '[{kind:"file-missing-but-required", branch:"*", severity:"critical"}]')
    total_drift=$((total_drift + 1))
    total_critical=$((total_critical + 1))
  fi
  if $file_present && [[ "$require_code_owner_reviews" == "true" ]]; then
    # File exists, profile requires gate — drift if any branch has the gate off.
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      gate_on=$(jq --arg n "$b" '[.[] | select(.name == $n and .actual != null and .actual.require_code_owner_reviews)] | length > 0' <<<"$branches_arr")
      if [[ "$gate_on" == "false" ]]; then
        co_drift=$(jq --arg b "$b" '. + [{kind:"file-present-but-gate-off", branch:$b, severity:"warn"}]' <<<"$co_drift")
        total_drift=$((total_drift + 1))
        total_warn=$((total_warn + 1))
      fi
    done < <(branches_for_strategy)
  fi

  codeowners_section=$(jq -n \
    --argjson fp "$file_present" \
    --argjson req "$([[ "$require_code_owner_reviews" == "true" ]] && echo true || echo false)" \
    --argjson bwg "$branches_with_gate" \
    --argjson drift "$co_drift" \
    '{file_present:$fp, gate_required_in_profile:$req, branches_with_gate:$bwg, drift:$drift}')

  # --- tag protection (Rulesets API) ---
  # Audit only when the profile declares an expected pattern. Reads
  # /repos/{o}/{r}/rulesets and finds the first one that targets tags
  # AND whose ref_name include patterns cover the expected pattern.
  # Drift kinds: pattern absent (no matching ruleset), deletion not
  # blocked, force-push not blocked. The legacy `tag_protection` API
  # is deprecated; the Rulesets API is the supported path.
  tag_skipped_section=""
  if [[ -z "$tag_protection_pattern" ]]; then
    tag_section=$(jq -n '{
      skipped: true,
      reason: "tag-protection-not-configured-in-profile"
    }')
    tag_skipped_section="tag_protection"
  else
    rulesets_raw=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/rulesets" 2>/dev/null || echo '[]')
    if [[ "$(jq -r 'type' <<<"$rulesets_raw")" != "array" ]]; then
      # 404 / permission error / list endpoint missing → soft skip.
      tag_section=$(jq -n '{
        skipped: true,
        reason: "rulesets-list-unreachable"
      }')
      tag_skipped_section="tag_protection"
    else
      # The list endpoint returns summaries; we need the per-ruleset
      # detail to see rules[]. Fetch each ruleset that targets tags.
      tag_pattern_glob="$tag_protection_pattern"
      ruleset_id="null"
      ruleset_name=""
      pattern_present=false
      blocks_deletion=false
      blocks_force_push=false
      while IFS= read -r rid; do
        [[ -z "$rid" || "$rid" == "null" ]] && continue
        detail=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/rulesets/${rid}" 2>/dev/null || echo '{}')
        target=$(jq -r '.target // ""' <<<"$detail")
        [[ "$target" != "tag" ]] && continue
        # Check that ref_name.include covers the expected pattern.
        # GitHub stores patterns with `refs/tags/` prefix; profile
        # declares the bare pattern (e.g. `v*`). Match either form.
        match_count=$(jq --arg p "$tag_pattern_glob" '
          (.conditions.ref_name.include // [])
          | map(select(. == ("refs/tags/" + $p) or . == $p or . == "~ALL"))
          | length
        ' <<<"$detail")
        [[ "$match_count" -eq 0 ]] && continue
        # Found a matching tag ruleset.
        pattern_present=true
        ruleset_id=$rid
        ruleset_name=$(jq -r '.name // ""' <<<"$detail")
        # Inspect rules[] for deletion + non_fast_forward (blocks force-push).
        deletion_count=$(jq '[.rules[]? | select(.type == "deletion")] | length' <<<"$detail")
        ff_count=$(jq '[.rules[]? | select(.type == "non_fast_forward")] | length' <<<"$detail")
        [[ "$deletion_count" -gt 0 ]] && blocks_deletion=true
        [[ "$ff_count" -gt 0 ]] && blocks_force_push=true
        # Don't break — the strictest match across rulesets wins. Two
        # rulesets each enabling one of the rules is still effective.
      done < <(jq -r '.[].id // empty' <<<"$rulesets_raw")

      tag_drift='[]'
      if ! $pattern_present; then
        tag_drift=$(jq -n --arg p "$tag_protection_pattern" '[
          {field:"pattern_present", expected:true, actual:false, severity:"critical"}
        ]')
        total_drift=$((total_drift + 1))
        total_critical=$((total_critical + 1))
      else
        if ! $blocks_deletion; then
          tag_drift=$(jq '. + [{field:"blocks_deletion", expected:true, actual:false, severity:"critical"}]' <<<"$tag_drift")
          total_drift=$((total_drift + 1))
          total_critical=$((total_critical + 1))
        fi
        if ! $blocks_force_push; then
          tag_drift=$(jq '. + [{field:"blocks_force_push", expected:true, actual:false, severity:"critical"}]' <<<"$tag_drift")
          total_drift=$((total_drift + 1))
          total_critical=$((total_critical + 1))
        fi
      fi

      tag_section=$(jq -n \
        --argjson pp "$pattern_present" \
        --argjson bd "$blocks_deletion" \
        --argjson bff "$blocks_force_push" \
        --argjson rid "$ruleset_id" \
        --arg name "$ruleset_name" \
        --argjson drift "$tag_drift" \
        '{pattern_present:$pp, blocks_deletion:$bd, blocks_force_push:$bff, ruleset_id:$rid, ruleset_name:$name, drift:$drift}')
    fi
  fi

  # --- repo security audit ---
  # Reads four signals from the GitHub API:
  #   * Dependabot alerts via `GET /repos/{o}/{r}/vulnerability-alerts`
  #     (returns 204 enabled / 404 disabled — gh exits 0 on 204 and
  #     non-zero on 404 when called via `--silent --include`).
  #   * Secret scanning via `.security_and_analysis.secret_scanning`
  #     on `GET /repos/{o}/{r}`.
  #   * Push protection via `.security_and_analysis.secret_scanning_push_protection`.
  #   * Code-scanning default setup via
  #     `GET /repos/{o}/{r}/code-scanning/default-setup` → `.state`
  #     (404 when the repo isn't eligible — treated as `not-applicable`).
  # Each signal resolves to enabled / disabled / unknown so consumers
  # can present a tri-state. Drift entries are `warn` severity — these
  # are good-practice gates, not preview-before-mutate invariants.
  security_skipped_section=""
  security_drift='[]'

  # Repo metadata for secret-scanning + push-protection.
  # gh api emits a 404/403 body that looks like {"message":"Not Found",
  # "documentation_url":"..."} — still a JSON object, but missing the
  # repo-shaped fields. Detect by absence of `id` (the canonical signal
  # for a successful repo response) plus the presence of `.message`
  # (the canonical error signal). Also handle the empty-body case.
  repo_meta=$("$gh_bin" api --method GET "/repos/${owner}/${repo}" 2>/dev/null || echo '')
  meta_has_id=$(jq -r '(.id // empty) != ""' <<<"$repo_meta" 2>/dev/null || echo false)
  meta_has_msg=$(jq -r '(.message // empty) != ""' <<<"$repo_meta" 2>/dev/null || echo false)
  if [[ -z "$repo_meta" ]] || \
     [[ "$(jq -r 'type' <<<"$repo_meta" 2>/dev/null || echo "")" != "object" ]] || \
     [[ "$meta_has_id" != "true" && "$meta_has_msg" == "true" ]]; then
    security_section=$(jq -n '{
      skipped: true,
      reason: "repo-metadata-unreachable"
    }')
    security_skipped_section="security"
  else
    secret_scanning_state=$(jq -r '.security_and_analysis.secret_scanning.status // "unknown"' <<<"$repo_meta")
    push_protection_state=$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"' <<<"$repo_meta")

    # Vulnerability alerts: 204 = enabled, 404 = disabled, anything
    # else (403 missing scope, 5xx, network, rate limit) = unknown.
    # Capture stderr so we can distinguish "endpoint says no" from
    # "couldn't reach endpoint" — the earlier `>/dev/null 2>&1`
    # collapsed every non-2xx into "disabled" which let auth +
    # transport errors masquerade as legitimate-but-disabled state.
    da_err=$(mktemp -t nyann-da.XXXXXX)
    if "$gh_bin" api --silent --method GET "/repos/${owner}/${repo}/vulnerability-alerts" >/dev/null 2>"$da_err"; then
      dependabot_alerts_state="enabled"
    elif grep -qF "Not Found" "$da_err" 2>/dev/null; then
      # Real 404 from gh — vulnerability alerts genuinely off.
      dependabot_alerts_state="disabled"
    else
      dependabot_alerts_state="unknown"
    fi
    rm -f "$da_err"

    # Code scanning default setup: 200 with .state, or 404 → not-applicable.
    cs_raw=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/code-scanning/default-setup" 2>/dev/null || echo '')
    if [[ -z "$cs_raw" ]] || [[ "$(jq -r '.message // empty' <<<"$cs_raw")" == "Not Found" ]] || \
       [[ "$(jq -r 'type' <<<"$cs_raw")" != "object" ]]; then
      code_scanning_state="not-applicable"
    else
      code_scanning_state=$(jq -r '.state // "unknown"' <<<"$cs_raw")
      # Some responses use "configured" / "not-configured" — normalise to
      # the audit-level enum.
      case "$code_scanning_state" in
        configured)     code_scanning_state="enabled" ;;
        not-configured) code_scanning_state="disabled" ;;
      esac
    fi

    # Build drift entries (warn severity; not critical). Only flag
    # the explicit "disabled" state — `unknown` (transport failure,
    # missing scope, transient API issue) is informational; we don't
    # know the real state, so we shouldn't pretend the user has a
    # gap. The schema preserves the tri-state in the report so
    # consumers can still see the unknown count.
    if [[ "$dependabot_alerts_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$dependabot_alerts_state" \
        '. + [{field:"dependabot_alerts", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi
    if [[ "$secret_scanning_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$secret_scanning_state" \
        '. + [{field:"secret_scanning", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi
    if [[ "$push_protection_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$push_protection_state" \
        '. + [{field:"secret_scanning_push_protection", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi
    # Code scanning: not-applicable is a non-finding (private repo on
    # a plan without code scanning). Only flag when explicitly disabled.
    if [[ "$code_scanning_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$code_scanning_state" \
        '. + [{field:"code_scanning_default_setup", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi

    sec_drift_count=$(jq 'length' <<<"$security_drift")
    total_drift=$((total_drift + sec_drift_count))
    total_warn=$((total_warn + sec_drift_count))

    security_section=$(jq -n \
      --arg da "$dependabot_alerts_state" \
      --arg ss "$secret_scanning_state" \
      --arg pp "$push_protection_state" \
      --arg cs "$code_scanning_state" \
      --argjson drift "$security_drift" \
      '{
        dependabot_alerts: $da,
        secret_scanning: $ss,
        secret_scanning_push_protection: $pp,
        code_scanning_default_setup: $cs,
        drift: $drift
      }')
  fi

  # --- signing audit ---
  # Reads branch protection's required_signatures.enabled per
  # strategy-declared branch (we already fetched protection above; the
  # `raw` variable is no longer in scope so we re-extract from the
  # branches_arr section by re-querying GitHub here for clarity).
  # Local config check covers commit.gpgsign + tag.gpgsign + presence
  # of user.signingkey. Drift severity:
  #   * profile requires signed commits + remote branch protection
  #     missing required_signatures → critical
  #   * profile requires signed commits + local commit.gpgsign=false
  #     → warn (the user's commits won't be signed, even though
  #     remote enforces it)
  #   * profile requires signed tags + local tag.gpgsign=false → warn
  #     (release.sh will produce unsigned tags despite the contract)
  #   * profile requires either + user.signingkey unset → warn
  #     (user can't actually sign anything)
  signing_branches='[]'
  signing_drift='[]'
  if [[ "$require_signed_commits" == "true" ]]; then
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      proto=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/branches/${b}/protection" 2>/dev/null || echo '{}')
      sig_enabled=$(jq -r '.required_signatures.enabled // false' <<<"$proto" 2>/dev/null || echo false)
      [[ -z "$sig_enabled" ]] && sig_enabled=false
      signing_branches=$(jq --arg n "$b" --argjson e "$sig_enabled" \
        '. + [{name:$n, required_signatures_enabled:$e}]' <<<"$signing_branches")
      if [[ "$sig_enabled" != "true" ]]; then
        signing_drift=$(jq --arg b "$b" \
          '. + [{field:"required_signatures_enabled", expected:true, actual:false, branch:$b, severity:"critical"}]' <<<"$signing_drift")
        total_drift=$((total_drift + 1))
        total_critical=$((total_critical + 1))
      fi
    done < <(branches_for_strategy)
  fi

  # Local config: read commit.gpgsign / tag.gpgsign / user.signingkey
  # from the target repo's git config. Failures (no .git dir, etc.)
  # leave them unset = false.
  commit_gpgsign=$(git -C "$target" config --get commit.gpgsign 2>/dev/null || echo "false")
  tag_gpgsign=$(git -C "$target" config --get tag.gpgsign 2>/dev/null || echo "false")
  user_signingkey=$(git -C "$target" config --get user.signingkey 2>/dev/null || echo "")
  [[ "$commit_gpgsign" == "true" ]] || commit_gpgsign=false
  [[ "$tag_gpgsign" == "true" ]] || tag_gpgsign=false
  [[ -n "$user_signingkey" ]] && user_signingkey_present=true || user_signingkey_present=false

  if [[ "$require_signed_commits" == "true" && "$commit_gpgsign" != "true" ]]; then
    signing_drift=$(jq '. + [{field:"local commit.gpgsign", expected:true, actual:false, severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  if [[ "$require_signed_tags" == "true" && "$tag_gpgsign" != "true" ]]; then
    signing_drift=$(jq '. + [{field:"local tag.gpgsign", expected:true, actual:false, severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  if { [[ "$require_signed_commits" == "true" ]] || [[ "$require_signed_tags" == "true" ]]; } \
     && [[ "$user_signingkey_present" != "true" ]]; then
    signing_drift=$(jq '. + [{field:"user.signingkey", expected:"present", actual:"unset", severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi

  signing_section=$(jq -n \
    --argjson req_commits "$([[ "$require_signed_commits" == "true" ]] && echo true || echo false)" \
    --argjson req_tags "$([[ "$require_signed_tags" == "true" ]] && echo true || echo false)" \
    --argjson branches "$signing_branches" \
    --argjson cs "$commit_gpgsign" \
    --argjson ts "$tag_gpgsign" \
    --argjson sk "$user_signingkey_present" \
    --argjson drift "$signing_drift" \
    '{
      commit_signing_required_in_profile: $req_commits,
      tag_signing_required_in_profile:    $req_tags,
      branches: $branches,
      local_config: {
        commit_gpgsign:          $cs,
        tag_gpgsign:             $ts,
        user_signingkey_present: $sk
      },
      drift: $drift
    }')

  # --- repo-settings audit ---
  # Reuses repo_meta fetched in the security section. When that fetch
  # was unreachable we soft-skip this section too (same root cause).
  # Default-branch expectation is profile.branching.base_branches[0]
  # (always set since the field is required); merge-button + delete-on-
  # merge expectations are tri-state (null = profile silent, no drift).
  repo_settings_skipped_section=""
  if [[ -n "$security_skipped_section" ]]; then
    repo_settings_section=$(jq -n '{
      skipped: true,
      reason: "repo-metadata-unreachable"
    }')
    repo_settings_skipped_section="repo_settings"
  else
    actual_default_branch=$(jq -r '.default_branch // ""' <<<"$repo_meta")
    actual_squash=$(jq -r '.allow_squash_merge // false' <<<"$repo_meta")
    actual_rebase=$(jq -r '.allow_rebase_merge // false' <<<"$repo_meta")
    actual_commit=$(jq -r '.allow_merge_commit // false' <<<"$repo_meta")
    actual_delete=$(jq -r '.delete_branch_on_merge // false' <<<"$repo_meta")

    rs_drift='[]'
    # Default branch — profile always declares it; mismatch is critical
    # (PRs would target the wrong base, branch protection would fall
    # on the wrong branch).
    db_matches=true
    if [[ "$actual_default_branch" != "$default_branch_expected" ]]; then
      db_matches=false
      rs_drift=$(jq --arg e "$default_branch_expected" --arg a "$actual_default_branch" \
        '. + [{field:"default_branch", expected:$e, actual:$a, severity:"critical"}]' <<<"$rs_drift")
      total_drift=$((total_drift + 1))
      total_critical=$((total_critical + 1))
    fi

    # Merge buttons + delete-on-merge: tri-state. Drift only fires
    # when profile expressed an expectation AND it disagrees with
    # actual. Severity is warn — these don't break anything, they're
    # workflow hygiene.
    rs_drift_helper() {
      # $1=field name, $2=expected ("true"|"false"|"null"), $3=actual ("true"|"false")
      local field="$1" exp="$2" act="$3"
      [[ "$exp" == "null" ]] && return 0
      if [[ "$exp" != "$act" ]]; then
        rs_drift=$(jq --arg f "$field" --argjson e "$exp" --argjson a "$act" \
          '. + [{field:$f, expected:$e, actual:$a, severity:"warn"}]' <<<"$rs_drift")
        total_drift=$((total_drift + 1))
        total_warn=$((total_warn + 1))
      fi
    }
    rs_drift_helper allow_squash_merge "$allow_squash_merge_expected" "$actual_squash"
    rs_drift_helper allow_rebase_merge "$allow_rebase_merge_expected" "$actual_rebase"
    rs_drift_helper allow_merge_commit "$allow_merge_commit_expected" "$actual_commit"
    rs_drift_helper delete_branch_on_merge "$delete_branch_on_merge_expected" "$actual_delete"

    # Build the section JSON. expected-fields are tri-state JSON
    # (null when profile silent, true/false when set). The
    # `if X == "null" then null else X|fromjson end` guard keeps the
    # null case representable without an `--argnull` jq flag.
    repo_settings_section=$(jq -n \
      --arg eDB "$default_branch_expected" \
      --arg aDB "$actual_default_branch" \
      --argjson dbMatches "$([[ "$db_matches" == "true" ]] && echo true || echo false)" \
      --arg eSq "$allow_squash_merge_expected" --argjson aSq "$actual_squash" \
      --arg eRb "$allow_rebase_merge_expected" --argjson aRb "$actual_rebase" \
      --arg eMc "$allow_merge_commit_expected" --argjson aMc "$actual_commit" \
      --arg eDl "$delete_branch_on_merge_expected" --argjson aDl "$actual_delete" \
      --argjson drift "$rs_drift" \
      '{
        default_branch:    { expected: $eDB, actual: $aDB, matches: $dbMatches },
        merge_buttons: {
          squash: { expected: (if $eSq == "null" then null else ($eSq | fromjson) end), actual: $aSq },
          rebase: { expected: (if $eRb == "null" then null else ($eRb | fromjson) end), actual: $aRb },
          commit: { expected: (if $eMc == "null" then null else ($eMc | fromjson) end), actual: $aMc }
        },
        delete_branch_on_merge: {
          expected: (if $eDl == "null" then null else ($eDl | fromjson) end),
          actual:   $aDl
        },
        drift: $drift
      }')
  fi

  # Build skipped_sections array: include only sections we soft-skipped.
  skipped_arr=()
  [[ -n "$tag_skipped_section" ]] && skipped_arr+=("$tag_skipped_section")
  [[ -n "$security_skipped_section" ]] && skipped_arr+=("$security_skipped_section")
  [[ -n "$repo_settings_skipped_section" ]] && skipped_arr+=("$repo_settings_skipped_section")
  if [[ ${#skipped_arr[@]} -eq 0 ]]; then
    skipped_sections='[]'
  else
    skipped_sections=$(printf '%s\n' "${skipped_arr[@]}" | jq -R . | jq -sc .)
  fi

  jq -n \
    --arg target "$target" \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --argjson branches "$branches_arr" \
    --argjson tag "$tag_section" \
    --argjson codeowners "$codeowners_section" \
    --argjson security "$security_section" \
    --argjson signing "$signing_section" \
    --argjson repo_settings "$repo_settings_section" \
    --argjson total_drift "$total_drift" \
    --argjson critical "$total_critical" \
    --argjson warn "$total_warn" \
    --argjson skipped "$skipped_sections" \
    '{
      target: $target,
      owner: $owner,
      repo: $repo,
      branches: $branches,
      tag_protection: $tag,
      codeowners_gate: $codeowners,
      security: $security,
      signing: $signing,
      repo_settings: $repo_settings,
      summary: { total_drift: $total_drift, critical: $critical, warn: $warn, skipped_sections: $skipped }
    }'
  exit 0
fi

# --- phase 4: per-strategy rule set ------------------------------------------

# Build the protection body as JSON. GitHub's contract requires the full body
# on PUT; partial updates aren't supported.
make_body() {
  local require_reviews="$1" require_checks="$2" strict="${3:-true}" co_required="${4:-false}"
  # require_checks is a CSV of check names; empty means "no status checks"
  # but the contract wants `null` for "no constraint" rather than empty.
  local checks_block
  if [[ -z "$require_checks" ]]; then
    checks_block='null'
  else
    checks_block=$(jq -n --arg checks "$require_checks" --argjson strict "$strict" '
      { strict: $strict, contexts: ($checks | split(",")) }
    ')
  fi
  jq -n --argjson rr "$require_reviews" --argjson checks "$checks_block" \
    --argjson co "$([[ "$co_required" == "true" ]] && echo true || echo false)" '
    {
      required_status_checks: $checks,
      enforce_admins: true,
      required_pull_request_reviews: (if $rr > 0 then {
        required_approving_review_count: $rr,
        dismiss_stale_reviews: true,
        require_code_owner_reviews: $co
      } else null end),
      restrictions: null,
      required_linear_history: false,
      allow_force_pushes: false,
      allow_deletions: false
    }
  '
}
# branches_for_strategy() defined earlier (shared between --check and --apply).

applied_json='[]'
noop_json='[]'
error_json='[]'

while IFS= read -r branch; do
  # Per-strategy body (trunk-based forces status checks "strict").
  case "$strategy" in
    trunk-based) body=$(make_body "$required_reviews" "$required_checks_csv" true  "$require_code_owner_reviews") ;;
    *)           body=$(make_body "$required_reviews" "$required_checks_csv" false "$require_code_owner_reviews") ;;
  esac

  # Read current protection. gh api returns a 404-shaped JSON body when the
  # branch has no protection; jq extraction is best-effort.
  current=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/branches/${branch}/protection" 2>/dev/null || echo '{}')

  # Don't weaken existing protection. Skip PUT when any monotone field
  # is already >= what we'd set, and raise-only when our body is a
  # strict superset.
  current_rr=$(jq -r '
    try .required_pull_request_reviews.required_approving_review_count catch 0
    | tonumber? // 0
  ' <<<"$current" 2>/dev/null || echo 0)
  [[ -z "$current_rr" ]] && current_rr=0

  # Existing required code-owner reviews?
  current_co=$(jq -r '.required_pull_request_reviews.require_code_owner_reviews // false' <<<"$current" 2>/dev/null || echo false)
  # Existing required status-check contexts (list).
  current_ctx_count=$(jq -r '[.required_status_checks.contexts // []] | flatten | length' <<<"$current" 2>/dev/null || echo 0)
  [[ -z "$current_ctx_count" ]] && current_ctx_count=0

  # The profile-derived body is "stricter-or-equal" only when every
  # monotone field is ≥ what's on remote. Downgrades → noop + warn.
  want_ctx_count=0
  if [[ -n "$required_checks_csv" ]]; then
    want_ctx_count=$(awk -F, '{ n = NF; for (i=1;i<=NF;i++) if ($i=="") n--; print n }' <<<"$required_checks_csv")
  fi

  would_downgrade=false
  reasons=()
  if (( current_rr > required_reviews )); then
    would_downgrade=true; reasons+=("reviews: remote=$current_rr > profile=$required_reviews")
  fi
  if [[ "$current_co" == "true" ]]; then
    would_downgrade=true; reasons+=("require_code_owner_reviews: remote=true (profile does not set)")
  fi
  if (( current_ctx_count > want_ctx_count )); then
    would_downgrade=true; reasons+=("required_status_checks.contexts: remote=$current_ctx_count > profile=$want_ctx_count")
  fi

  if $would_downgrade; then
    reason_str=$(printf '%s; ' "${reasons[@]}")
    reason_str="${reason_str%; }"
    noop_json=$(jq --arg b "$branch" --arg reason "$reason_str" --argjson cur "$current_rr" --argjson req "$required_reviews" '
      . + [{branch:$b, reason:"remote-stricter", detail:$reason, current_reviews:$cur, profile_reviews:$req}]
    ' <<<"$noop_json")
    continue
  fi

  # Apply via PUT only when our body is strictly-or-equally protective.
  : > "$apply_err"
  if "$gh_bin" api --method PUT \
      -H "Accept: application/vnd.github+json" \
      "/repos/${owner}/${repo}/branches/${branch}/protection" \
      --input - <<<"$body" >/dev/null 2>"$apply_err"; then
    applied_json=$(jq --arg b "$branch" --arg s "$strategy" '
      . + [{branch:$b, strategy:$s}]
    ' <<<"$applied_json")
  else
    # Cap stderr at 500 bytes so a multi-MB error page from a hostile
    # proxy / GH Enterprise doesn't bloat our output.
    err_msg=$(head -c 500 "$apply_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    error_json=$(jq --arg b "$branch" --arg msg "$err_msg" '
      . + [{branch:$b, error:$msg}]
    ' <<<"$error_json")
  fi
done < <(branches_for_strategy)

jq -n \
  --arg owner "$owner" \
  --arg repo "$repo" \
  --arg strategy "$strategy" \
  --argjson applied "$applied_json" \
  --argjson noop "$noop_json" \
  --argjson errors "$error_json" \
  '{owner:$owner, repo:$repo, strategy:$strategy, applied:$applied, noop:$noop, errors:$errors}'
