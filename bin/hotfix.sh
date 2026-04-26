#!/usr/bin/env bash
# hotfix.sh — set up the branch topology for a patch release against
# a previously tagged version.
#
# Usage:
#   hotfix.sh --target <repo> --from <tag> --slug <slug>
#             [--release-branch <name>] [--checkout]
#
# Behavior:
#   * Resolves <tag> locally; refuses if it doesn't exist.
#   * Derives release_branch from the tag's SemVer major.minor
#     (e.g. v1.2.3 → release/1.2). Overridable via --release-branch.
#   * Creates the release branch from the tag if it doesn't already
#     exist locally. Idempotent: existing branch is reused.
#   * Creates a fresh hotfix/<slug> branch off the release branch.
#     Refuses if the branch already exists.
#   * With --checkout: switches to the hotfix branch.
#
# After this script: user commits the fix on the hotfix branch, then
# runs `/nyann:release --version <patch>` (e.g. 1.2.4) from there.
# release.sh's pre-release detection routes a -rc.1 suffix through
# the prerelease path automatically.
#
# Output: HotfixResult JSON (see schemas/hotfix-result.schema.json).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
source_tag=""
slug=""
release_branch_override=""
do_checkout=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --from)            source_tag="${2:-}"; shift 2 ;;
    --from=*)          source_tag="${1#--from=}"; shift ;;
    --slug)            slug="${2:-}"; shift 2 ;;
    --slug=*)          slug="${1#--slug=}"; shift ;;
    --release-branch)  release_branch_override="${2:-}"; shift 2 ;;
    --release-branch=*) release_branch_override="${1#--release-branch=}"; shift ;;
    --checkout)        do_checkout=true; shift ;;
    -h|--help)         sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" && -d "$target/.git" ]] || nyann::die "$target is not a git repo"
target="$(cd "$target" && pwd)"
[[ -n "$source_tag" ]] || nyann::die "--from <tag> is required"
[[ -n "$slug" ]]       || nyann::die "--slug <slug> is required"

# Slug shape mirrors new-branch.sh's safety bar: lowercase + alnum +
# hyphen only, can't start with `-`.
if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  nyann::die "--slug must match ^[a-z0-9][a-z0-9-]*$ (lowercase + digits + hyphens, no leading dash): got '$slug'"
fi

# Tag must exist locally. Refuse explicitly so the user knows to fetch
# tags first if they're hotfixing from a remote-only release.
if ! git -C "$target" rev-parse --verify --quiet "refs/tags/${source_tag}" >/dev/null; then
  nyann::die "tag '$source_tag' not found locally — run 'git fetch --tags origin' if it exists upstream"
fi

# Derive release_branch from the tag's major.minor. Strip the `v`
# prefix if present, then take the first two SemVer components.
if [[ -n "$release_branch_override" ]]; then
  release_branch="$release_branch_override"
else
  bare="${source_tag#v}"
  if ! [[ "$bare" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
    nyann::die "tag '$source_tag' is not SemVer-shaped (vX.Y.Z); pass --release-branch <name> explicitly"
  fi
  release_branch="release/${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
fi

hotfix_branch="hotfix/${slug}"

# Refuse to silently overwrite an existing hotfix branch — the user
# has work-in-progress there if it's local, and a stale upstream of
# the same name should be investigated, not stomped.
if git -C "$target" show-ref --verify --quiet "refs/heads/${hotfix_branch}"; then
  nyann::die "branch '$hotfix_branch' already exists locally — pick a different --slug or 'git branch -D ${hotfix_branch}' first"
fi

# Create the release branch from the source tag IF it doesn't exist.
# Idempotent: existing release branch is reused, but ONLY when its
# tip already contains the source tag in its history. If the release
# branch has moved past --from (e.g. a previous patch added v1.2.4
# while the user is asking to hotfix off v1.2.3) we'd silently base
# the new hotfix on un-released work. Refuse with a clear pointer to
# the conflict.
release_branch_created=false
source_sha=$(git -C "$target" rev-parse --verify --quiet "refs/tags/${source_tag}^{commit}")
if ! git -C "$target" show-ref --verify --quiet "refs/heads/${release_branch}"; then
  git -C "$target" branch -- "$release_branch" "refs/tags/${source_tag}" >/dev/null \
    || nyann::die "failed to create release branch '$release_branch' from tag '$source_tag'"
  release_branch_created=true
else
  # Branch exists. The new hotfix must build on top of the same commit
  # as --from; if the branch tip has moved past it (a previous patch
  # tagged v1.2.4 onto release/1.2 while the user is asking for a new
  # hotfix off v1.2.3), forking the hotfix from the branch tip would
  # silently include unrelated commits in the patch lineage. Require
  # branch tip == source tag SHA exactly.
  release_sha=$(git -C "$target" rev-parse --verify --quiet "refs/heads/${release_branch}")
  if [[ "$release_sha" != "$source_sha" ]]; then
    nyann::die "release branch '$release_branch' tip is at $release_sha, but --from $source_tag points at $source_sha. Hotfix would either skip commits or include unrelated work. Either pass --from \$(git rev-parse $release_branch) to fork from the current tip, or pass --release-branch <name> to use a different branch."
  fi
fi

# Create the hotfix branch from the release branch.
git -C "$target" branch -- "$hotfix_branch" "refs/heads/${release_branch}" >/dev/null \
  || nyann::die "failed to create hotfix branch '$hotfix_branch' from '$release_branch'"
hotfix_branch_created=true

# Optional checkout. Captures the outcome separately so the JSON
# can report failure (e.g. dirty tree) without burning the whole flow.
checked_out=null
if $do_checkout; then
  if git -C "$target" checkout -q "$hotfix_branch" 2>/dev/null; then
    checked_out=true
  else
    checked_out=false
    nyann::warn "couldn't checkout $hotfix_branch (dirty tree?). Run 'git checkout $hotfix_branch' manually."
  fi
fi

# Build next_steps[].
# release.sh operates on the current branch (HEAD) — it does NOT
# accept --base. The correct flow after committing the fix on the
# hotfix branch is:
#   1. git checkout <release_branch>
#   2. git merge --no-ff <hotfix_branch>
#   3. /nyann:release --version <patch> --push   (release.sh uses HEAD)
# Earlier next_steps emitted `--base <release_branch>` which would
# die on the very next command (`unknown argument: --base`).
next_steps_json='[]'
add_next_step() {
  next_steps_json=$(jq --arg s "$1" '. + [$s]' <<<"$next_steps_json")
}
if [[ "$checked_out" != "true" ]]; then
  add_next_step "git checkout $hotfix_branch"
fi
add_next_step "# Make your fix, then:"
add_next_step "git add -A && /nyann:commit"

# Suggest the patch version: bare = source_tag minus 'v', bump patch.
patch_hint=""
bare="${source_tag#v}"
if [[ "$bare" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  patch_hint="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
fi
add_next_step "# When the fix is committed, merge into the release branch and tag:"
add_next_step "git checkout $release_branch && git merge --no-ff $hotfix_branch"
if [[ -n "$patch_hint" ]]; then
  add_next_step "/nyann:release --version $patch_hint --push"
else
  add_next_step "/nyann:release --version <patch-version> --push"
fi
add_next_step "# Optionally clean up the hotfix branch afterwards:"
add_next_step "/nyann:cleanup-branches"

jq -n \
  --arg target "$target" \
  --arg source_tag "$source_tag" \
  --arg release_branch "$release_branch" \
  --arg hotfix_branch "$hotfix_branch" \
  --argjson rb_created "$release_branch_created" \
  --argjson hb_created "$hotfix_branch_created" \
  --argjson checked_out "$checked_out" \
  --argjson next_steps "$next_steps_json" \
  '{
    target: $target,
    source_tag: $source_tag,
    release_branch: $release_branch,
    hotfix_branch: $hotfix_branch,
    release_branch_created: $rb_created,
    hotfix_branch_created:  $hb_created,
    next_steps: $next_steps
  }
  + (if $checked_out == null then {} else {checked_out: $checked_out} end)'
