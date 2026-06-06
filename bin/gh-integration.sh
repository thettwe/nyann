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
# NB: any gh api call MUST come AFTER owner/repo validation below,
# even read-only ones. The security test asserts no api call leaks
# before that gate (a malicious owner like '..attacker' must not
# trigger any network round-trip).

# --- phase 3: load profile ---------------------------------------------------

tmp_profile=$(mktemp -t nyann-gh-profile.XXXXXX)
load_err=$(mktemp -t nyann-gh-load.XXXXXX)
apply_err=$(mktemp -t nyann-gh-apply.XXXXXX)
trap 'rm -f "$tmp_profile" "$load_err" "$apply_err"' EXIT
"${_script_dir}/load-profile.sh" "$profile_name" --user-root "$user_root" > "$tmp_profile" 2>"$load_err" || {
  cat "$load_err" >&2; rm -f "$tmp_profile"; exit 2
}

# Profile fields — consumed by sourced modules in gh-integration/.
# shellcheck disable=SC2034
strategy=$(jq -r '.branching.strategy' "$tmp_profile")
# .github.enable_branch_protection: explicit false wins. //true only fires on
# null/missing — `false // true` would incorrectly coerce.
enable=$(jq -r 'if .github.enable_branch_protection == false then "false" else "true" end' "$tmp_profile")
# shellcheck disable=SC2034
required_reviews=$(jq -r '.github.require_pr_reviews // 1' "$tmp_profile")
# Defense-in-depth: require_pr_reviews flows into apply-protection.sh's
# `(( current_rr > required_reviews ))` arithmetic and into make_body's
# `--argjson rr`. A non-numeric profile value (currently only shielded
# incidentally by jq's coercion ordering) would make that arithmetic
# error or splice a bad token into the PUT body. Pin it to digits here;
# fall back to the schema default (1) on anything else.
if ! [[ "$required_reviews" =~ ^[0-9]+$ ]]; then
  nyann::warn "require_pr_reviews '$required_reviews' is not numeric — falling back to 1"
  required_reviews=1
fi
# shellcheck disable=SC2034
required_checks_csv=$(jq -r '.github.require_status_checks // [] | join(",")' "$tmp_profile")
# shellcheck disable=SC2034
require_code_owner_reviews=$(jq -r '.github.require_code_owner_reviews // false' "$tmp_profile")
# shellcheck disable=SC2034
tag_protection_pattern=$(jq -r '.github.tag_protection_pattern // ""' "$tmp_profile")
# shellcheck disable=SC2034
require_signed_commits=$(jq -r '.github.require_signed_commits // false' "$tmp_profile")
# shellcheck disable=SC2034
require_signed_tags=$(jq -r '.github.require_signed_tags // false' "$tmp_profile")
# Repo-settings audit fields (repo-config). `null` = profile silent
# on that button; the audit treats it as "no opinion" and emits no drift.
# shellcheck disable=SC2034
allow_squash_merge_expected=$(jq -r 'if .github.allow_squash_merge == null then "null" else (.github.allow_squash_merge|tostring) end' "$tmp_profile")
# shellcheck disable=SC2034
allow_rebase_merge_expected=$(jq -r 'if .github.allow_rebase_merge == null then "null" else (.github.allow_rebase_merge|tostring) end' "$tmp_profile")
# shellcheck disable=SC2034
allow_merge_commit_expected=$(jq -r 'if .github.allow_merge_commit == null then "null" else (.github.allow_merge_commit|tostring) end' "$tmp_profile")
# shellcheck disable=SC2034
delete_branch_on_merge_expected=$(jq -r 'if .github.delete_branch_on_merge == null then "null" else (.github.delete_branch_on_merge|tostring) end' "$tmp_profile")
# shellcheck disable=SC2034
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

# Cheap upfront rate-limit probe (deferred until AFTER owner/repo
# validation above so a malicious owner can't trigger a network
# round-trip — see security-hardening test). Each `gh api` probe in
# phase 4a silences stderr by design (404 = feature absent is the
# common case); the trade-off is that an exhausted rate limit also
# falls back silently. A single warn here surfaces that risk without
# introducing per-probe error checking.
if rate_json=$("$gh_bin" api /rate_limit 2>/dev/null); then
  rl_remaining=$(jq -r '.resources.core.remaining // 5000' <<<"$rate_json" 2>/dev/null || echo 5000)
  if [[ "$rl_remaining" =~ ^[0-9]+$ ]] && (( rl_remaining < 50 )); then
    nyann::warn "gh API rate-limit low ($rl_remaining/5000 remaining); audit results may be incomplete (probes silently fall back to defaults on rate-limit failure)"
  fi
fi

# --- source modules -----------------------------------------------------------
_gh_dir="${_script_dir}/gh-integration"
# shellcheck source=gh-integration/_helpers.sh
source "${_gh_dir}/_helpers.sh"

# --- --check (read-only audit) ------------------------------------------------

if $check_only; then
  # shellcheck disable=SC2034
  branches_arr='[]'
  # shellcheck disable=SC2034
  total_drift=0
  # shellcheck disable=SC2034
  total_critical=0
  # shellcheck disable=SC2034
  total_warn=0

  # shellcheck source=gh-integration/audit-branch-protection.sh
  source "${_gh_dir}/audit-branch-protection.sh"
  # shellcheck source=gh-integration/audit-codeowners.sh
  source "${_gh_dir}/audit-codeowners.sh"
  # shellcheck source=gh-integration/audit-tag-protection.sh
  source "${_gh_dir}/audit-tag-protection.sh"
  # shellcheck source=gh-integration/audit-security.sh
  source "${_gh_dir}/audit-security.sh"
  # shellcheck source=gh-integration/audit-signing.sh
  source "${_gh_dir}/audit-signing.sh"
  # shellcheck source=gh-integration/audit-repo-settings.sh
  source "${_gh_dir}/audit-repo-settings.sh"

  exit 0
fi

# shellcheck source=gh-integration/apply-protection.sh
source "${_gh_dir}/apply-protection.sh"
