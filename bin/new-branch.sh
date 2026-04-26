#!/usr/bin/env bash
# new-branch.sh — create a strategy-compliant git branch.
#
# Usage:
#   new-branch.sh --target <repo> --profile <name>
#                 --purpose <feature|bugfix|release|hotfix>
#                 --slug <slug>
#                 [--version <x.y.z>]
#                 [--checkout]
#
# Flow:
#   1. Load the profile via bin/load-profile.sh (user overrides starter).
#   2. Look up branch_name_patterns[purpose].
#   3. Substitute {slug} / {version}; validate resulting name.
#   4. Pick the correct base:
#        github-flow / trunk-based → first base_branch (usually main)
#        gitflow                   → develop for features/bugfix,
#                                    main for release/hotfix
#   5. Create the branch (git branch <name> <base>), optionally checkout.
#
# Exit codes:
#   0 — created (or already existed and --checkout switched to it)
#   2 — profile missing
#   3 — invalid purpose for the active strategy
#   4 — invalid slug (must match ^[a-z0-9][a-z0-9._-]*$)
#   5 — branch already exists and --checkout wasn't passed (caller picks)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_name=""
purpose=""
slug=""
version=""
do_checkout=false
user_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2:-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --profile)    profile_name="${2:-}"; shift 2 ;;
    --profile=*)  profile_name="${1#--profile=}"; shift ;;
    --purpose)    purpose="${2:-}"; shift 2 ;;
    --purpose=*)  purpose="${1#--purpose=}"; shift ;;
    --slug)       slug="${2:-}"; shift 2 ;;
    --slug=*)     slug="${1#--slug=}"; shift ;;
    --version)    version="${2:-}"; shift 2 ;;
    --version=*)  version="${1#--version=}"; shift ;;
    --checkout)   do_checkout=true; shift ;;
    --user-root)  user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    -h|--help)    sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

user_root="${user_root:-${HOME}/.claude/nyann}"

[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"
target="$(cd "$target" && pwd)"
[[ -n "$profile_name" ]] || nyann::die "--profile is required"
[[ -n "$purpose" ]]      || nyann::die "--purpose is required"

# Slug validation runs later (after we know whether the pattern uses {slug}).
# If a slug was provided, sanity-check the shape now so we fail fast.
if [[ -n "$slug" ]] && ! [[ "$slug" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  nyann::warn "invalid slug: $slug"
  nyann::warn "slugs must start with a lowercase letter or digit and contain only [a-z0-9._-]"
  exit 4
fi

# Version validation: same semver shape release.sh already enforces. Without
# this, a caller could substitute arbitrary content (whitespace, `..`, quotes)
# into the branch-name pattern and end up with a ref that collides with
# worktree paths or breaks CI branch-matching rules.
if [[ -n "$version" ]] && ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  nyann::warn "invalid version: $version"
  nyann::warn "versions must be semver (x.y.z or x.y.z-prerelease)"
  exit 4
fi

# Load profile (user overrides starter).
tmp_profile=$(mktemp -t nyann-branch-profile.XXXXXX)
load_err=$(mktemp -t nyann-newbranch.XXXXXX)
trap 'rm -f "$tmp_profile" "$load_err"' EXIT
"${_script_dir}/load-profile.sh" "$profile_name" --user-root "$user_root" > "$tmp_profile" 2>"$load_err" || {
  cat "$load_err" >&2; rm -f "$tmp_profile"; exit 2
}

strategy=$(jq -r '.branching.strategy // "github-flow"' "$tmp_profile")
pattern=$(jq -r --arg p "$purpose" '.branching.branch_name_patterns[$p] // ""' "$tmp_profile")

if [[ -z "$pattern" ]]; then
  nyann::warn "strategy $strategy does not declare a pattern for purpose=$purpose"
  rm -f "$tmp_profile"
  exit 3
fi

# Substitute {slug} / {version}. Require each only if the pattern declares it.
if [[ "$pattern" == *"{slug}"* ]] && [[ -z "$slug" ]]; then
  nyann::warn "pattern '$pattern' needs --slug"
  rm -f "$tmp_profile"
  exit 3
fi
if [[ "$pattern" == *"{version}"* ]] && [[ -z "$version" ]]; then
  nyann::warn "pattern '$pattern' needs --version"
  rm -f "$tmp_profile"
  exit 3
fi

branch_name="$pattern"
[[ -n "$slug"    ]] && branch_name="${branch_name//\{slug\}/$slug}"
[[ -n "$version" ]] && branch_name="${branch_name//\{version\}/$version}"

# Guard against unsubstituted placeholders (should be impossible after the
# two checks above, but double-guard).
if [[ "$branch_name" == *\{*\}* ]]; then
  nyann::warn "branch name still has placeholders: $branch_name"
  rm -f "$tmp_profile"
  exit 3
fi

# A profile pattern like "--upload-pack=cmd" would flow into
# `git branch "$branch_name"` → git parses it as an option. Reject
# names starting with '-' before the git call for a better error.
if [[ "$branch_name" == -* ]]; then
  nyann::warn "branch name rejected (starts with '-' — would be parsed as git option): $branch_name"
  rm -f "$tmp_profile"
  exit 3
fi

# Choose base branch.
first_base=$(jq -r '.branching.base_branches[0] // "main"' "$tmp_profile")
if ! nyann::valid_git_ref "$first_base"; then
  nyann::warn "base branch from profile rejected as unsafe git ref: $first_base"
  rm -f "$tmp_profile"
  exit 3
fi
case "$strategy:$purpose" in
  gitflow:feature|gitflow:bugfix) base="develop" ;;
  gitflow:release|gitflow:hotfix) base="$first_base" ;;
  *)                               base="$first_base" ;;
esac

# Verify base exists.
if ! git -C "$target" rev-parse --verify "$base" >/dev/null 2>&1; then
  nyann::warn "base branch '$base' does not exist in $target"
  rm -f "$tmp_profile"
  exit 3
fi

# If branch already exists, either switch (on --checkout) or report.
# Use `refs/heads/` prefix for rev-parse and `--` separator on
# `git branch` so a name starting with '-' is treated as a positional.
# Note: `git checkout` does NOT use `--` here — it would treat the
# name as a pathspec. The leading-dash guard at line 131 covers checkout.
if git -C "$target" rev-parse --verify "refs/heads/$branch_name" >/dev/null 2>&1; then
  if $do_checkout; then
    git -C "$target" checkout -q "$branch_name"
    nyann::log "switched to existing branch: $branch_name"
    rm -f "$tmp_profile"
    exit 0
  fi
  nyann::warn "branch already exists: $branch_name"
  nyann::warn "re-run with --checkout to switch to it"
  rm -f "$tmp_profile"
  exit 5
fi

git -C "$target" branch -- "$branch_name" "$base"
nyann::log "created $branch_name from $base"
if $do_checkout; then
  git -C "$target" checkout -q "$branch_name"
  nyann::log "checked out $branch_name"
fi

rm -f "$tmp_profile"
echo "$branch_name"
