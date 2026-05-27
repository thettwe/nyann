#!/usr/bin/env bash
# release-workspace.sh — release a single workspace within a monorepo.
#
# Usage:
#   release-workspace.sh --target <repo> --workspace <path>
#                        --version <x.y.z> [--tag-prefix <prefix>]
#                        [--scopes <csv>] [--changelog-mode per-workspace|unified]
#                        [--dry-run] [--yes]
#
# Creates a workspace-scoped changelog section, scoped tag, and optional
# manifest bumps. Does NOT commit or push — the caller (release.sh)
# batches workspace releases into a single commit when --batch-commit.
#
# Output (JSON on stdout): WorkspaceReleaseResult
#   { workspace, version, tag, commits[], changelog_section, status }

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

target="$PWD"
workspace=""
version=""
tag_prefix=""
scope_csv=""
changelog_mode="per-workspace"
dry_run=false
confirm=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --workspace)       workspace="${2:-}"; shift 2 ;;
    --workspace=*)     workspace="${1#--workspace=}"; shift ;;
    --version)         version="${2:-}"; shift 2 ;;
    --version=*)       version="${1#--version=}"; shift ;;
    --tag-prefix)      tag_prefix="${2:-}"; shift 2 ;;
    --tag-prefix=*)    tag_prefix="${1#--tag-prefix=}"; shift ;;
    --scopes)          scope_csv="${2:-}"; shift 2 ;;
    --scopes=*)        scope_csv="${1#--scopes=}"; shift ;;
    --changelog-mode)  changelog_mode="${2:-}"; shift 2 ;;
    --changelog-mode=*) changelog_mode="${1#--changelog-mode=}"; shift ;;
    --dry-run)         dry_run=true; shift ;;
    --yes)             confirm=true; shift ;;
    -h|--help)         sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "release-workspace: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "release-workspace: --target must be a directory"
target="$(cd "$target" && pwd)"
[[ -n "$workspace" ]] || nyann::die "release-workspace: --workspace is required"
[[ -n "$version" ]] || nyann::die "release-workspace: --version is required"

ws_name=$(basename "$workspace")
if [[ -z "$tag_prefix" ]]; then
  tag_prefix="${ws_name}@"
fi
tag="${tag_prefix}${version}"

if git -C "$target" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  nyann::die "release-workspace: tag $tag already exists"
fi

# Find the last tag for this workspace
last_tag=$(git -C "$target" tag --list "${tag_prefix}*" --sort=-v:refname 2>/dev/null | head -n1)
if [[ -n "$last_tag" ]]; then
  from_ref="$last_tag"
else
  from_ref=$(git -C "$target" rev-list --max-parents=0 HEAD 2>/dev/null | head -n1)
fi

# Collect workspace-scoped commits
commits_json=$("${_script_dir}/detect-workspace-changes.sh" \
  --target "$target" --workspace "$workspace" --from "$from_ref" \
  ${scope_csv:+--scopes "$scope_csv"})

n_commits=$(jq 'length' <<<"$commits_json")
if (( n_commits == 0 )); then
  jq -n --arg ws "$workspace" --arg version "$version" --arg tag "$tag" --arg from "$from_ref" \
    '{workspace:$ws, version:$version, tag:$tag, from:$from, commits:[], changelog_section:"", status:"noop"}'
  exit 0
fi

# Render changelog section for this workspace
changelog_section=$(echo "$commits_json" | "${_script_dir}/render-changelog.sh" --version "$version")

if $dry_run; then
  jq -n \
    --arg ws "$workspace" \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg from "$from_ref" \
    --argjson commits "$commits_json" \
    --arg changelog "$changelog_section" \
    '{workspace:$ws, version:$version, tag:$tag, from:$from, commits:$commits, changelog_section:$changelog, status:"preview", dry_run:true}'
  exit 0
fi

# Write changelog (per-workspace mode: write to <workspace>/CHANGELOG.md)
if [[ "$changelog_mode" == "per-workspace" ]]; then
  ws_changelog="$target/$workspace/CHANGELOG.md"
  [[ -L "$ws_changelog" ]] && nyann::die "release-workspace: refusing to write via symlink: $ws_changelog"
  mkdir -p "$(dirname "$ws_changelog")"
  if [[ -f "$ws_changelog" ]]; then
    existing=$(cat "$ws_changelog")
    printf '%s\n%s' "$changelog_section" "$existing" > "$ws_changelog"
  else
    printf '# Changelog\n\n%s' "$changelog_section" > "$ws_changelog"
  fi
fi

jq -n \
  --arg ws "$workspace" \
  --arg version "$version" \
  --arg tag "$tag" \
  --arg from "$from_ref" \
  --argjson commits "$commits_json" \
  --arg changelog "$changelog_section" \
  '{workspace:$ws, version:$version, tag:$tag, from:$from, commits:$commits, changelog_section:$changelog, status:"released"}'
