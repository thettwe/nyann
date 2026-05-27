#!/usr/bin/env bash
# release.sh — cut a release: generate CHANGELOG from conventional commits,
# create a release commit + annotated tag.
#
# Usage:
#   release.sh --target <repo> --version <x.y.z>
#              [--strategy conventional-changelog|manual|changesets|release-please]
#              [--changelog <path>]         # default: CHANGELOG.md
#              [--tag-prefix <prefix>]      # default: v
#              [--from <ref>]               # default: latest tag matching prefix
#              [--push]                     # also push tag to origin
#              [--dry-run]                  # print what would happen, mutate nothing
#              [--wait-for-checks]          # gate the tag step on green CI for HEAD's PR
#              [--wait-for-checks-timeout <sec>]  # default 1800
#              [--wait-for-checks-interval <sec>] # default 30
#              [--allow-no-pr]              # allow --wait-for-checks when no PR matches HEAD (off by default)
#              [--allow-no-checks]          # allow --wait-for-checks when PR has no checks attached (off by default)
#              [--gh <path>]                # gh binary, default `gh`
#
# Output (JSON on stdout):
#   {
#     "status":    "released" | "skipped" | "noop",
#     "strategy":  "...",
#     "version":   "x.y.z",
#     "tag":       "vx.y.z",
#     "from":      "vx.y.(z-1)",
#     "commits":   [{sha, type, scope, subject}],
#     "changelog": "<rendered block>",
#     "pushed":    true|false
#   }
#
# Strategies:
#   - conventional-changelog: full flow (group commits, write CHANGELOG,
#     release commit, annotated tag). Handles the common case.
#   - manual: just annotated tag at HEAD; no CHANGELOG work.
#   - changesets / release-please: soft-skip with a note — those are
#     separate tool ecosystems nyann doesn't duplicate.
#
# Exit codes:
#   0 — released, skipped (soft), or noop
#   2 — hard error (bad version, not a git repo, dirty tree, invalid strategy)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_release_dir="${_script_dir}/release"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
version=""
strategy="conventional-changelog"
changelog_path="CHANGELOG.md"
tag_prefix="v"
from_ref=""
push=false
dry_run=false
confirm=false
wait_for_checks=false
wait_timeout=1800
wait_interval=30
allow_no_pr=false
allow_no_checks=false
gh_bin="gh"
bump_manifests=false
gh_release=false
profile_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         target="${2:-}"; shift 2 ;;
    --target=*)       target="${1#--target=}"; shift ;;
    --version)        version="${2:-}"; shift 2 ;;
    --version=*)      version="${1#--version=}"; shift ;;
    --strategy)       strategy="${2:-}"; shift 2 ;;
    --strategy=*)     strategy="${1#--strategy=}"; shift ;;
    --changelog)      changelog_path="${2:-}"; shift 2 ;;
    --changelog=*)    changelog_path="${1#--changelog=}"; shift ;;
    --tag-prefix)     tag_prefix="${2:-}"; shift 2 ;;
    --tag-prefix=*)   tag_prefix="${1#--tag-prefix=}"; shift ;;
    --from)           from_ref="${2:-}"; shift 2 ;;
    --from=*)         from_ref="${1#--from=}"; shift ;;
    --push)           push=true; shift ;;
    --dry-run)        dry_run=true; shift ;;
    --yes)            confirm=true; shift ;;
    --wait-for-checks)         wait_for_checks=true; shift ;;
    --wait-for-checks-timeout) wait_timeout="${2:-}"; shift 2 ;;
    --wait-for-checks-timeout=*) wait_timeout="${1#--wait-for-checks-timeout=}"; shift ;;
    --wait-for-checks-interval) wait_interval="${2:-}"; shift 2 ;;
    --wait-for-checks-interval=*) wait_interval="${1#--wait-for-checks-interval=}"; shift ;;
    --allow-no-pr)    allow_no_pr=true; shift ;;
    --allow-no-checks) allow_no_checks=true; shift ;;
    --gh)             gh_bin="${2:-}"; shift 2 ;;
    --gh=*)           gh_bin="${1#--gh=}"; shift ;;
    --bump-manifests) bump_manifests=true; shift ;;
    --gh-release)     gh_release=true; shift ;;
    --profile)        profile_path="${2:-}"; shift 2 ;;
    --profile=*)      profile_path="${1#--profile=}"; shift ;;
    -h|--help)        sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

if $wait_for_checks; then
  [[ "$wait_timeout" =~ ^[0-9]+$ && "$wait_timeout" -ge 1 ]]   || nyann::die "--wait-for-checks-timeout must be a positive integer"
  [[ "$wait_interval" =~ ^[0-9]+$ && "$wait_interval" -ge 1 ]] || nyann::die "--wait-for-checks-interval must be a positive integer"
fi

# --- validate inputs ---------------------------------------------------------

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

[[ -n "$version" ]] || nyann::die "--version <x.y.z> is required"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  nyann::die "--version must be semver (x.y.z or x.y.z-prerelease): got '$version'"
fi

is_prerelease=false
if [[ "$version" == *-* ]]; then
  is_prerelease=true
fi

case "$strategy" in
  conventional-changelog|manual|changesets|release-please) ;;
  *) nyann::die "--strategy must be conventional-changelog|manual|changesets|release-please" ;;
esac

if $bump_manifests && [[ "$strategy" == "manual" ]]; then
  nyann::die "--bump-manifests requires --strategy conventional-changelog (manual strategy creates no commit for the bumps to land in)"
fi

if $bump_manifests && [[ "$version" == *-* ]]; then
  nyann::die "--bump-manifests is not supported on prerelease versions ($version): the prerelease path skips the release commit, so the bumps would be silently dropped. Cut the stable version with --bump-manifests, or run release.sh on a prerelease without --bump-manifests."
fi

if $gh_release && ! $push; then
  nyann::die "--gh-release requires --push (the GitHub release attaches to the pushed tag)"
fi

if [[ -n "$tag_prefix" ]] && ! [[ "$tag_prefix" =~ ^[A-Za-z0-9._/-]*$ ]]; then
  nyann::die "--tag-prefix must contain only [A-Za-z0-9._/-]: got '$tag_prefix'"
fi

if [[ "$changelog_path" == /* || "$changelog_path" == *".."* ]]; then
  nyann::die "--changelog path must be repo-relative and cannot contain '..': got '$changelog_path'"
fi
nyann::assert_path_under_target "$target" "$target/$changelog_path" "--changelog" >/dev/null

if [[ -n "$from_ref" ]] && ! nyann::valid_git_ref "$from_ref"; then
  nyann::die "--from must be a valid git ref: got '$from_ref'"
fi

tag="${tag_prefix}${version}"

# --- signal-rollback state ---------------------------------------------------

_rollback_dir=""
_mutation_in_progress=false
_rollback_files=()
_bump_plan_file=""

_rollback_on_signal() {
  trap - INT TERM HUP
  if $_mutation_in_progress && [[ -n "$_rollback_dir" && -d "$_rollback_dir" ]]; then
    nyann::warn "release: signal received mid-mutation; restoring working tree from snapshot ($_rollback_dir)"
    local _f _full _snap
    for _f in "${_rollback_files[@]}"; do
      _full="$target/$_f"
      _snap="$_rollback_dir/$_f"
      if [[ -f "$_snap.existed" ]]; then
        if ! cp "$_snap" "$_full" 2>/dev/null; then
          nyann::warn "rollback: failed to restore $_f from snapshot"
        fi
      else
        if ! rm -f "$_full" 2>/dev/null; then
          nyann::warn "rollback: failed to remove $_f"
        fi
      fi
    done
  fi
  exit 130
}

trap 'rm -rf ${_rollback_dir:+"$_rollback_dir"} ${_bump_plan_file:+"$_bump_plan_file"}' EXIT

# --- soft-skip paths ---------------------------------------------------------

skip() {
  jq -n --arg reason "$1" --arg strategy "$strategy" --arg version "$version" --arg tag "$tag" \
    '{status:"skipped", strategy:$strategy, version:$version, tag:$tag, reason:$reason}'
  exit 0
}

case "$strategy" in
  changesets)
    skip "use the changesets CLI directly — nyann does not duplicate it"
    ;;
  release-please)
    skip "release-please runs as a GitHub Action — nyann does not duplicate it"
    ;;
esac

# --- tag existence + clean tree ---------------------------------------------

if git -C "$target" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  nyann::die "tag $tag already exists"
fi

if ! $dry_run; then
  if ! git -C "$target" diff --quiet || ! git -C "$target" diff --cached --quiet; then
    nyann::die "working tree has uncommitted changes; commit or stash first"
  fi
fi

# --- resolve from-ref --------------------------------------------------------

if [[ -z "$from_ref" ]]; then
  latest_tag=$(git -C "$target" tag --list "${tag_prefix}*" --sort=-v:refname | head -n1)
  if [[ -n "$latest_tag" ]]; then
    from_ref="$latest_tag"
    log_range="${from_ref}..HEAD"
  else
    from_ref="$(git -C "$target" rev-list --max-parents=0 HEAD | head -n1)"
    log_range="HEAD"
  fi
fi

if [[ -n "$from_ref" ]] && ! nyann::valid_git_ref "$from_ref"; then
  nyann::die "resolved from-ref is not a valid git ref: $from_ref"
fi

if [[ -z "${log_range:-}" ]]; then
  log_range="${from_ref}..HEAD"
fi

# --- collect commits via module -----------------------------------------------

commits_json=$("${_release_dir}/collect-commits.sh" --target "$target" --log-range "$log_range") || exit $?

n_commits=$(jq 'length' <<<"$commits_json")
if (( n_commits == 0 )) && [[ "$strategy" == "conventional-changelog" ]]; then
  jq -n --arg strategy "$strategy" --arg version "$version" --arg tag "$tag" --arg from "$from_ref" \
    '{status:"noop", strategy:$strategy, version:$version, tag:$tag, from:$from, reason:"no commits since $from"}'
  exit 0
fi

# --- render changelog via module ----------------------------------------------

changelog_block=""
if [[ "$strategy" == "conventional-changelog" ]]; then
  changelog_block=$(echo "$commits_json" | "${_release_dir}/render-changelog.sh" --version "$version") || exit $?
fi

# --- manifest bumps via module ------------------------------------------------

bumped_files_json='[]'
_bump_plan_file=""

if $bump_manifests; then
  bump_args=(--mode compute --target "$target" --version "$version")
  if [[ -n "$profile_path" ]]; then
    bump_args+=(--profile "$profile_path")
  fi
  if $dry_run; then
    bump_args+=(--dry-run)
  fi
  bump_result=$("${_release_dir}/bump-manifests.sh" "${bump_args[@]}") || exit $?
  bumped_files_json=$(jq '.bumped_files' <<<"$bump_result")

  plan_count=$(jq '.plan | length' <<<"$bump_result")
  if (( plan_count > 0 )); then
    _bump_plan_file=$(mktemp -t nyann-bump-plan.XXXXXX)
    jq '.' <<<"$bump_result" > "$_bump_plan_file"
  fi
fi

# --- dry-run output -----------------------------------------------------------

pushed=false
if $dry_run; then
  jq -n \
    --arg status "released" \
    --arg strategy "$strategy" \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg from "$from_ref" \
    --arg changelog "$changelog_block" \
    --argjson commits "$commits_json" \
    --argjson pushed "$pushed" \
    --argjson prerelease "$is_prerelease" \
    --argjson bumped "$bumped_files_json" \
    --argjson bump_on "$($bump_manifests && echo true || echo false)" \
    '{status:$status, strategy:$strategy, version:$version, tag:$tag, from:$from,
      commits:$commits, changelog:$changelog, pushed:$pushed, next_steps:[],
      prerelease:$prerelease, dry_run:true}
     + (if $bump_on then {bumped_files:$bumped} else {} end)'
  exit 0
fi

# --- CI gate via module -------------------------------------------------------

ci_gate_json=""
if $wait_for_checks; then
  ci_gate_args=(--target "$target" --gh "$gh_bin" --timeout "$wait_timeout" --interval "$wait_interval")
  if $allow_no_pr; then
    ci_gate_args+=(--allow-no-pr)
  fi
  if $allow_no_checks; then
    ci_gate_args+=(--allow-no-checks)
  fi
  ci_gate_json=$("${_release_dir}/ci-gate.sh" "${ci_gate_args[@]}") || exit $?
fi

# --- mutation phase (stays in orchestrator for rollback safety) ---------------

case "$strategy" in
  conventional-changelog)
    if ! $confirm; then
      {
        printf 'release.sh: preview-before-mutate — rendered CHANGELOG block:\n\n'
        printf '%s\n\n' "$changelog_block"
        if $is_prerelease; then
          printf '(prerelease detected: %s — CHANGELOG will NOT be modified, the [Unreleased] section stays queued for the eventual stable release; only the tag is created.)\n\n' "$version"
        fi
        printf 'Re-run with --yes to write to %s and create the release commit.\n' "$changelog_path"
        printf '(Or re-run with --dry-run to see the full JSON plan first.)\n'
      } >&2
      exit 2
    fi

    if $is_prerelease; then
      :
    else
      # Snapshot for rollback
      _rollback_dir=$(mktemp -d -t nyann-release-rollback.XXXXXX)
      _rollback_files=("$changelog_path")

      if [[ -n "$_bump_plan_file" ]]; then
        local_bump_paths=()
        while IFS= read -r bp; do
          local_bump_paths+=("$bp")
        done < <(jq -r '.plan[].path' "$_bump_plan_file" 2>/dev/null)
        _rollback_files+=("${local_bump_paths[@]}")
      fi

      for _rb_f in "${_rollback_files[@]}"; do
        _rb_full="$target/$_rb_f"
        if [[ -f "$_rb_full" ]]; then
          mkdir -p "$_rollback_dir/$(dirname "$_rb_f")" 2>/dev/null || true
          cp "$_rb_full" "$_rollback_dir/$_rb_f" 2>/dev/null || true
          : > "$_rollback_dir/$_rb_f.existed"
        fi
      done
      _mutation_in_progress=true
      trap _rollback_on_signal INT TERM HUP

      # Write CHANGELOG
      full_changelog="$target/$changelog_path"
      [[ -L "$full_changelog" ]] && nyann::die "refusing to write CHANGELOG via symlink: $full_changelog"
      tmp_changelog=$(mktemp -t nyann-changelog.XXXXXX)
      if [[ -f "$full_changelog" ]]; then
        existing=$(cat "$full_changelog")
        printf '%s\n%s' "$changelog_block" "$existing" > "$tmp_changelog"
      else
        {
          printf '# Changelog\n\n'
          printf 'All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com).\n\n'
          printf '%s' "$changelog_block"
        } > "$tmp_changelog"
      fi
      mv "$tmp_changelog" "$full_changelog"

      # Apply manifest bumps via module
      if [[ -n "$_bump_plan_file" ]]; then
        "${_release_dir}/bump-manifests.sh" --mode apply \
          --target "$target" --version "$version" \
          --plan-file "$_bump_plan_file" >/dev/null
      fi

      # Release commit
      nyann::resolve_identity "$target"
      git -C "$target" add -- "$changelog_path"

      if [[ -n "$_bump_plan_file" ]]; then
        local_bump_paths=()
        while IFS= read -r bp; do
          local_bump_paths+=("$bp")
        done < <(jq -r '.plan[].path' "$_bump_plan_file" 2>/dev/null)
        if (( ${#local_bump_paths[@]} > 0 )); then
          git -C "$target" add -- "${local_bump_paths[@]}"
        fi
      fi

      git -C "$target" \
        -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
        commit -q -m "chore(release): $tag" >/dev/null

      _mutation_in_progress=false
      trap - INT TERM HUP
      rm -rf "$_rollback_dir"
      _rollback_dir=""
    fi
    ;;
  manual)
    ;;
esac

# --- tag creation -------------------------------------------------------------

nyann::resolve_identity "$target"
git -C "$target" \
  -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
  tag -a -m "release $tag" -- "$tag"

# --- push via module ----------------------------------------------------------

next_steps_json='[]'
tag_pushed=false

if $push; then
  push_args=(--target "$target" --tag "$tag" --strategy "$strategy")
  if $is_prerelease; then
    push_args+=(--is-prerelease)
  fi
  push_result=$("${_release_dir}/push-release.sh" "${push_args[@]}") || true
  pushed=$(jq -r '.pushed' <<<"$push_result" 2>/dev/null || echo "false")
  tag_pushed=$(jq -r '.tag_pushed' <<<"$push_result" 2>/dev/null || echo "false")
  push_steps=$(jq '.next_steps' <<<"$push_result" 2>/dev/null || echo '[]')
  next_steps_json=$(jq --argjson steps "$push_steps" '. + $steps' <<<"$next_steps_json")
else
  pushed=false
fi

# --- GitHub release via module ------------------------------------------------

gh_release_json=""
if $gh_release; then
  gh_args=(--tag "$tag" --gh "$gh_bin")
  if [[ -n "$changelog_block" ]]; then
    gh_args+=(--changelog-block "$changelog_block")
  fi
  if $is_prerelease; then
    gh_args+=(--is-prerelease)
  fi
  if [[ "$tag_pushed" != "true" ]]; then
    gh_args+=(--tag-not-pushed)
  fi
  gh_result=$("${_release_dir}/github-release.sh" "${gh_args[@]}") || true
  gh_release_json=$(jq 'del(.next_steps)' <<<"$gh_result" 2>/dev/null || echo '{}')
  gh_steps=$(jq '.next_steps // []' <<<"$gh_result" 2>/dev/null || echo '[]')
  next_steps_json=$(jq --argjson steps "$gh_steps" '. + $steps' <<<"$next_steps_json")
fi

# --- final JSON output --------------------------------------------------------

ci_gate_arg=${ci_gate_json:-null}
gh_release_arg=${gh_release_json:-null}
jq -n \
  --arg status "released" \
  --arg strategy "$strategy" \
  --arg version "$version" \
  --arg tag "$tag" \
  --arg from "$from_ref" \
  --arg changelog "$changelog_block" \
  --argjson commits "$commits_json" \
  --argjson pushed "$pushed" \
  --argjson next_steps "$next_steps_json" \
  --argjson prerelease "$is_prerelease" \
  --argjson ci_gate "$ci_gate_arg" \
  --argjson bumped "$bumped_files_json" \
  --argjson bump_on "$($bump_manifests && echo true || echo false)" \
  --argjson gh_release "$gh_release_arg" \
  '{status:$status, strategy:$strategy, version:$version, tag:$tag, from:$from,
    commits:$commits, changelog:$changelog, pushed:$pushed, next_steps:$next_steps,
    prerelease:$prerelease}
   + (if $ci_gate    != null then {ci_gate:    $ci_gate}    else {} end)
   + (if $bump_on             then {bumped_files: $bumped}  else {} end)
   + (if $gh_release != null then {gh_release: $gh_release} else {} end)'

if $push && [[ "$pushed" != "true" ]]; then
  exit 3
fi
