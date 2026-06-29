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
#              [--no-wait-for-checks]       # opt out of the CI gate that --push enables by default
#              [--wait-for-checks-timeout <sec>]  # default 1800
#              [--wait-for-checks-interval <sec>] # default 30
#              [--allow-no-pr]              # allow --wait-for-checks when no PR matches HEAD (off by default)
#              [--allow-no-checks]          # allow --wait-for-checks when PR has no checks attached (off by default)
#
# CI gate default: --push pushes a tag a marketplace consumes, so it
# enables the CI gate automatically. When auto-enabled it degrades
# gracefully — a release cut on main with no open PR, or a host without
# an authenticated gh, proceeds with a warning instead of failing. An
# explicit --wait-for-checks stays strict (no PR / no checks / no gh is
# fatal). Use --no-wait-for-checks to push without any gate.
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
#   2 — hard error (bad version, not a git repo, dirty tree, invalid strategy,
#       tag creation failed)
#   3 — --push requested but the tag/branch push did not complete
#   4 — --gh-release requested but `gh release create` failed (tag may be pushed;
#       see gh_release.next_steps[] in the JSON for recovery)

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
no_wait_for_checks=false
wait_timeout=1800
wait_interval=30
allow_no_pr=false
allow_no_checks=false
gh_bin="gh"
bump_manifests=false
allow_scripts=false
gh_release=false
profile_path=""
workspace_path=""
all_workspaces=false
iac_units_file=""
batch_commit=false

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
    --no-wait-for-checks)      no_wait_for_checks=true; shift ;;
    --wait-for-checks-timeout) wait_timeout="${2:-}"; shift 2 ;;
    --wait-for-checks-timeout=*) wait_timeout="${1#--wait-for-checks-timeout=}"; shift ;;
    --wait-for-checks-interval) wait_interval="${2:-}"; shift 2 ;;
    --wait-for-checks-interval=*) wait_interval="${1#--wait-for-checks-interval=}"; shift ;;
    --allow-no-pr)    allow_no_pr=true; shift ;;
    --allow-no-checks) allow_no_checks=true; shift ;;
    --gh)             gh_bin="${2:-}"; shift 2 ;;
    --gh=*)           gh_bin="${1#--gh=}"; shift ;;
    --bump-manifests) bump_manifests=true; shift ;;
    --allow-scripts)  allow_scripts=true; shift ;;
    --gh-release)     gh_release=true; shift ;;
    --profile)        profile_path="${2:-}"; shift 2 ;;
    --profile=*)      profile_path="${1#--profile=}"; shift ;;
    --workspace)      workspace_path="${2:-}"; shift 2 ;;
    --workspace=*)    workspace_path="${1#--workspace=}"; shift ;;
    --all-workspaces) all_workspaces=true; shift ;;
    --iac-units)      iac_units_file="${2:-}"; shift 2 ;;
    --iac-units=*)    iac_units_file="${1#--iac-units=}"; shift ;;
    --batch-commit)   batch_commit=true; shift ;;
    -h|--help)        sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# Security default: a pushed tag is consumed by the marketplace, so gate it on
# green CI unless the caller explicitly opted out. Only auto-enable when gh is
# actually usable — otherwise a developer pushing a release from a host without
# gh (or on main with no open PR) would suddenly hit a hard failure where the
# previous behaviour just pushed. Auto mode therefore also flips on the
# allow-no-pr / allow-no-checks degradations so a missing PR/checks warns
# instead of aborting. An explicit --wait-for-checks stays strict.
auto_wait=false
if $push && ! $wait_for_checks && ! $no_wait_for_checks && ! $dry_run; then
  _origin_url=$(git -C "$target" config --get remote.origin.url 2>/dev/null || echo "")
  if [[ "$_origin_url" != *github.com* ]]; then
    : # non-GitHub origin (or none): ci-gate can't apply — push as before.
  elif command -v "$gh_bin" >/dev/null 2>&1 && "$gh_bin" auth status >/dev/null 2>&1; then
    wait_for_checks=true
    auto_wait=true
    allow_no_pr=true
    allow_no_checks=true
  else
    nyann::warn "release: pushing a GitHub tag without a CI gate (gh unavailable or unauthenticated). Pass --wait-for-checks once gh is set up, or --no-wait-for-checks to silence this."
  fi
fi

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

# --- monorepo workspace release path -----------------------------------------
# When --workspace or --all-workspaces is set, delegate to release-workspace.sh
# instead of the single-repo flow below.

if [[ -n "$workspace_path" ]] || $all_workspaces || [[ -n "$iac_units_file" ]]; then
  ws_results='[]'

  # ws_list is a TAB-separated stream: `path<TAB>kind<TAB>name`. Code workspaces
  # carry empty kind/name (no --kind passed -> v1.11.0 behavior, unchanged). IaC
  # units carry their kind/name and are emitted in dependency-FIRST topological
  # order so a bumped module is tagged before a chart that references it.
  if [[ -n "$iac_units_file" ]]; then
    [[ -f "$iac_units_file" ]] || nyann::die "--iac-units file not found: $iac_units_file"
    jq -e 'type == "array"' "$iac_units_file" >/dev/null 2>&1 \
      || nyann::die "--iac-units must be a JSON array of units"
    # Topo-order the unit PATHS (dependency-first), then join each path back to
    # its {kind,name} from the units file. release.sh owns the ordering; the
    # cycle-safe best-effort fallback lives in topo-order-units.sh (never aborts).
    _ordered_paths=$("${_release_dir}/topo-order-units.sh" --units-file "$iac_units_file")
    ws_list=""
    while IFS= read -r _up; do
      [[ -z "$_up" ]] && continue
      _rec=$(jq -r --arg p "$_up" \
        'map(select(.path == $p)) | .[0] | [.path, (.kind // ""), (.name // "")] | @tsv' \
        "$iac_units_file")
      ws_list="${ws_list}${ws_list:+$'\n'}${_rec}"
    done <<<"$_ordered_paths"
    if [[ -z "$ws_list" ]]; then
      nyann::die "--iac-units: no releasable units found"
    fi
  elif [[ -n "$workspace_path" ]]; then
    ws_list="$workspace_path"
  else
    if [[ -n "$profile_path" && -f "$profile_path" ]]; then
      ws_list=$(jq -r '.workspaces[]?.path // empty' "$profile_path" 2>/dev/null)
    else
      ws_list=$(jq -r '.workspaces[]?.path // empty' "${target}/.nyann-profile.json" 2>/dev/null || true)
    fi
    if [[ -z "$ws_list" ]]; then
      nyann::die "--all-workspaces: no workspaces found in profile"
    fi
  fi

  ws_args=(--target "$target" --version "$version")
  if $dry_run; then
    ws_args+=(--dry-run)
  fi
  if $confirm; then
    ws_args+=(--yes)
  fi

  pending_tags=()
  released_workspaces=()

  while IFS=$'\t' read -r ws ws_kind ws_name; do
    [[ -z "$ws" ]] && continue

    # A unit path that is not a directory must NOT be silently dropped — doing
    # so let the run still report status:"released" with workspaces:[] (a false
    # success that tagged NOTHING). Two non-dir shapes are handled HONESTLY:
    #
    #   - A FILE path (CDK `lib/db-stack.ts`, Pulumi `Pulumi.prod.yaml`): a real
    #     unit, but NOT independently path-releasable in nyann's per-workspace
    #     model — there is no per-unit directory to host <path>/CHANGELOG.md (the
    #     path IS a file), and CDK/Pulumi stacks carry no version manifest to
    #     bump and no depends_on (cross-stack edges live in program code; see
    #     discover-iac-units.sh). Record a `skipped` result with a clear reason
    #     so the operator sees it; never a phantom `released`.
    #   - A path that exists as neither file nor dir: a genuinely missing unit.
    #     Record an `error` result (the existing non-zero exit path then fires).
    #
    # Either way the unit is captured in workspaces[] and counted, so the
    # all-dropped case can no longer masquerade as a plain success.
    if [[ ! -d "$target/$ws" ]]; then
      if [[ -e "$target/$ws" ]]; then
        nyann::warn "release: unit '$ws' is a file path, not a releasable directory (CDK/Pulumi stack files are not independently path-releasable); skipping"
        ws_result=$(jq -n --arg ws "$ws" --arg kind "${ws_kind:-}" \
          '{workspace:$ws, status:"skipped", reason:"file-path unit is not independently releasable (no per-unit directory for a CHANGELOG; no version manifest or depends_on)"}
           + (if $kind != "" then {unit_kind:$kind} else {} end)')
      else
        nyann::warn "release: unit path not found: $ws"
        ws_result=$(jq -n --arg ws "$ws" --arg kind "${ws_kind:-}" \
          '{workspace:$ws, status:"error", reason:"unit path not found"}
           + (if $kind != "" then {unit_kind:$kind} else {} end)')
      fi
      ws_results=$(jq --argjson r "$ws_result" '. + [$r]' <<<"$ws_results")
      continue
    fi

    ws_unit_args=()
    [[ -n "${ws_kind:-}" ]] && ws_unit_args+=(--kind "$ws_kind")
    [[ -n "${ws_name:-}" ]] && ws_unit_args+=(--name "$ws_name")

    # Expand ws_unit_args defensively: it is empty for code workspaces and
    # `set -u` (from _lib.sh) makes a bare "${arr[@]}" on an empty array an
    # "unbound variable" error on bash 3.2. The +-guard yields nothing when empty.
    ws_result=$("${_release_dir}/release-workspace.sh" "${ws_args[@]}" --workspace "$ws" \
      ${ws_unit_args[@]+"${ws_unit_args[@]}"}) || true
    if [[ -z "$ws_result" ]] || ! jq -e . <<<"$ws_result" >/dev/null 2>&1; then
      ws_result=$(jq -n --arg ws "$ws" '{workspace:$ws, status:"error"}')
    fi
    ws_results=$(jq --argjson r "$ws_result" '. + [$r]' <<<"$ws_results")

    ws_status=$(jq -r '.status' <<<"$ws_result" 2>/dev/null || echo "error")
    ws_tag=$(jq -r '.tag' <<<"$ws_result" 2>/dev/null || echo "")

    if [[ "$ws_status" == "released" && -n "$ws_tag" ]] && ! $dry_run; then
      released_workspaces+=("$ws")
      if $batch_commit; then
        pending_tags+=("$ws_tag")
      else
        # Non-batch: release-workspace.sh wrote <ws>/CHANGELOG.md but did NOT
        # commit. Commit this workspace's changelog FIRST, then tag, so the tag
        # lands on the commit that actually contains its changelog (mirrors the
        # single-repo commit→tag flow) and the working tree is left clean.
        # Without this, the tag would point at the pre-changelog HEAD and the
        # changelog would linger uncommitted.
        nyann::resolve_identity "$target"
        ws_changelog="$target/$ws/CHANGELOG.md"
        if [[ -f "$ws_changelog" ]]; then
          git -C "$target" add -- "$ws/CHANGELOG.md"
          if ! git -C "$target" diff --cached --quiet; then
            git -C "$target" \
              -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
              commit -q -m "chore(release): $ws_tag" >/dev/null
          fi
        fi
        git -C "$target" \
          -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
          tag -a -m "release $ws_tag" -- "$ws_tag"
        nyann::log "tagged: $ws_tag"
      fi
    fi
  done <<<"$ws_list"

  if $batch_commit && ! $dry_run && (( ${#released_workspaces[@]} > 0 )); then
    nyann::resolve_identity "$target"
    for ws in "${released_workspaces[@]}"; do
      ws_changelog="$target/$ws/CHANGELOG.md"
      [[ -f "$ws_changelog" ]] && git -C "$target" add -- "$ws/CHANGELOG.md"
    done
    changed=$(git -C "$target" diff --cached --name-only 2>/dev/null || true)
    if [[ -n "$changed" ]]; then
      git -C "$target" \
        -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
        commit -q -m "chore(release): workspace releases for v${version}" >/dev/null
    fi
    for ws_tag in "${pending_tags[@]}"; do
      git -C "$target" \
        -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
        tag -a -m "release $ws_tag" -- "$ws_tag"
      nyann::log "tagged: $ws_tag"
    done
  fi

  ws_total=$(jq 'length' <<<"$ws_results")
  ws_error_count=$(jq '[.[] | select(.status == "error")] | length' <<<"$ws_results")
  # A dry-run unit reports status "preview"; a real release reports "released".
  ws_released_count=$(jq '[.[] | select(.status == "released" or .status == "preview")] | length' <<<"$ws_results")

  # Top-level status must reflect what actually happened, so an all-dropped run
  # can NEVER report a plain "released":
  #   - >=1 unit released/previewed -> "released"
  #   - 0 released, but units WERE requested and at least one was a clean
  #     skip/noop (e.g. all units are CDK/Pulumi file paths, or all unchanged)
  #     -> "noop" (honest: nothing was tagged, but nothing errored either)
  #   - any "error" entry -> "released"/"noop" by the rule above, but the
  #     non-zero exit below still surfaces it.
  if (( ws_released_count > 0 )); then
    overall_status="released"
  else
    overall_status="noop"
  fi

  jq -n \
    --arg status "$overall_status" \
    --arg strategy "$strategy" \
    --arg version "$version" \
    --argjson workspaces "$ws_results" \
    --argjson dry_run "$($dry_run && echo true || echo false)" \
    '{status:$status, strategy:$strategy, version:$version, workspaces:$workspaces}
     + (if $dry_run then {dry_run:true} else {} end)'

  # Non-zero exit when the run did not honestly succeed:
  #   - any unit errored, OR
  #   - units were requested but NONE were released (the all-dropped case BUG 1
  #     used to mask as exit 0). A run where every unit is an up-to-date noop is
  #     fine (released_count counts releases only), so the all-noop case is NOT
  #     forced non-zero — but the all-file-path/all-missing case, which lands
  #     here with skipped/error entries and zero releases, IS.
  if (( ws_error_count > 0 )); then
    exit 1
  fi
  ws_skipped_count=$(jq '[.[] | select(.status == "skipped")] | length' <<<"$ws_results")
  if (( ws_released_count == 0 && ws_total > 0 && ws_skipped_count > 0 )); then
    nyann::warn "release: requested $ws_total unit(s) but released 0 — $ws_skipped_count skipped as not independently releasable. Nothing was tagged."
    exit 1
  fi
  exit 0
fi

# --- signal-rollback state ---------------------------------------------------

_rollback_dir=""
_mutation_in_progress=false
_rollback_files=()
_bump_plan_file=""
_release_commit_made=false

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

# Idempotency guard: if a prior run wrote the CHANGELOG section but then died
# before (or during) tag creation, the tag-exists check above won't fire (no tag
# was ever created). Re-running would prepend a SECOND "## [version]" block and
# create a second release commit. Refuse instead, and point at recovery.
# Scoped to the conventional-changelog stable path — prerelease and manual
# strategies don't write the CHANGELOG, so the marker can never be theirs.
if ! $dry_run && [[ "$strategy" == "conventional-changelog" ]] && ! $is_prerelease; then
  _full_changelog="$target/$changelog_path"
  if [[ -f "$_full_changelog" ]] && grep -Fq "## [$version]" "$_full_changelog"; then
    nyann::die "CHANGELOG already contains a '## [$version]' section but tag $tag does not exist — a prior release run likely failed after writing the CHANGELOG but before tagging. Inspect the working tree: if the release commit is present, create the tag manually ('git tag -a $tag'); otherwise 'git reset --hard HEAD~1' to drop the partial release commit, then re-run."
  fi
fi

if ! $dry_run; then
  if ! git -C "$target" diff --quiet || ! git -C "$target" diff --cached --quiet; then
    nyann::die "working tree has uncommitted changes; commit or stash first"
  fi
fi

# --- resolve from-ref --------------------------------------------------------

if [[ -z "$from_ref" ]]; then
  latest_tag=$(git -C "$target" -c versionsort.suffix=- tag --list "${tag_prefix}*" --sort=-v:refname | head -n1)
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
  if $allow_scripts; then
    bump_args+=(--allow-scripts)
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
  $auto_wait && nyann::log "release: --push enabled the CI gate by default (use --no-wait-for-checks to skip)"
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
        bump_apply_args=(--mode apply --target "$target" --version "$version"
          --plan-file "$_bump_plan_file")
        $allow_scripts && bump_apply_args+=(--allow-scripts)
        "${_release_dir}/bump-manifests.sh" "${bump_apply_args[@]}" >/dev/null
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
      _release_commit_made=true

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

# If tag creation fails (e.g. tag.gpgsign=true with no signing key), the release
# commit (made above) is already on the branch but no tag exists. Under set -e a
# bare `git tag` failure would exit here, stranding that commit: a re-run would
# prepend a SECOND CHANGELOG block and create a SECOND release commit (the
# tag-exists guard can't fire — no tag was created). So on failure we drop the
# just-created release commit before dying, restoring the pre-release state.
nyann::resolve_identity "$target"
if ! git -C "$target" \
  -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
  tag -a -m "release $tag" -- "$tag"; then
  if ${_release_commit_made:-false}; then
    nyann::warn "release: tag creation for $tag failed; dropping the just-created release commit to avoid a half-applied release"
    git -C "$target" reset --hard HEAD~1 >/dev/null 2>&1 || \
      nyann::warn "release: failed to roll back the release commit — inspect with 'git log -1' and reset manually"
  fi
  nyann::die "release: failed to create tag $tag (check tag.gpgsign / signing key, or tag protection)"
fi

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
gh_release_outcome=""
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
  gh_release_outcome=$(jq -r '.outcome // ""' <<<"$gh_result" 2>/dev/null || echo "")
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

# A failed `gh release create` must not pass silently as exit 0 — the tag may be
# pushed but the GitHub release the user asked for is missing. Surface a distinct
# non-zero so callers/CI can detect it (the JSON above carries gh_release.outcome
# and next_steps[] for recovery). Push failures (exit 3 above) take precedence.
if [[ "$gh_release_outcome" == "failed" ]]; then
  exit 4
fi
