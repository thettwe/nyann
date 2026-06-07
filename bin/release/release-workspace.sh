#!/usr/bin/env bash
# release-workspace.sh — release a single workspace OR IaC unit in a monorepo.
#
# Usage:
#   release-workspace.sh --target <repo> --workspace <path>
#                        --version <x.y.z> [--tag-prefix <prefix>]
#                        [--kind module|chart|stack|overlay|role|playbook]
#                        [--scopes <csv>] [--changelog-mode per-workspace|unified]
#                        [--dry-run] [--yes]
#
# Creates a unit-scoped changelog section + scoped tag. Does NOT commit or push
# — the caller (release.sh) batches releases into a single commit when
# --batch-commit (tags then land on that commit; ordering owned by release.sh).
#
# A "workspace" is any releasable unit:
#   - code package (package.json / Cargo.toml monorepo) — no --kind, default
#     scoped tag `<basename>@<version>` (e.g. core@2.1.0). UNCHANGED by I10.
#   - IaC unit (--kind from the descriptor's iac.units[]) — tool-idiomatic,
#     COLLISION-SAFE tag prefix derived per kind (see below).
#
# Per-kind tag conventions (when --tag-prefix is not given explicitly):
#   chart   -> `<chart-name>-<version>`   (Helm convention, e.g. app-0.4.0)
#   module  -> `<unit-path>/v<version>`   (path-scoped, e.g. modules/vpc/v1.3.0)
#   stack |
#   overlay |
#   role |
#   playbook-> `<unit-path>/v<version>`   (path-scoped)
# Path-scoping the module/stack tag is what prevents a unit tag from EVER
# colliding with a repo-wide `vX.Y.Z`: `modules/vpc/v1.3.0` shares no namespace
# with `v1.3.0`. A chart tag `app-0.4.0` likewise can't equal `vX.Y.Z`. The
# existing rev-parse tag-exists guard then catches any exact duplicate.
#
# Output (JSON on stdout): WorkspaceReleaseResult
#   { workspace, version, tag, commits[], changelog_section, status [, unit_kind] }

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

target="$PWD"
workspace=""
version=""
tag_prefix=""
tag_prefix_explicit=false
kind=""
unit_name=""
scope_csv=""
changelog_mode="per-workspace"
dry_run=false
# confirm: --yes is accepted for interface parity with release.sh (which passes
# it through), but workspace release is non-interactive (no prompt to confirm),
# so the value is intentionally unread.
confirm=false

# shellcheck disable=SC2034  # --yes sets confirm for interface parity only; unread (see above)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --workspace)       workspace="${2:-}"; shift 2 ;;
    --workspace=*)     workspace="${1#--workspace=}"; shift ;;
    --version)         version="${2:-}"; shift 2 ;;
    --version=*)       version="${1#--version=}"; shift ;;
    --tag-prefix)      tag_prefix="${2:-}"; tag_prefix_explicit=true; shift 2 ;;
    --tag-prefix=*)    tag_prefix="${1#--tag-prefix=}"; tag_prefix_explicit=true; shift ;;
    --kind)            kind="${2:-}"; shift 2 ;;
    --kind=*)          kind="${1#--kind=}"; shift ;;
    --name)            unit_name="${2:-}"; shift 2 ;;
    --name=*)          unit_name="${1#--name=}"; shift ;;
    --scopes)          scope_csv="${2:-}"; shift 2 ;;
    --scopes=*)        scope_csv="${1#--scopes=}"; shift ;;
    --changelog-mode)  changelog_mode="${2:-}"; shift 2 ;;
    --changelog-mode=*) changelog_mode="${1#--changelog-mode=}"; shift ;;
    --dry-run)         dry_run=true; shift ;;
    --yes)             confirm=true; shift ;;
    -h|--help)         sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "release-workspace: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "release-workspace: --target must be a directory"
target="$(cd "$target" && pwd)"
[[ -n "$workspace" ]] || nyann::die "release-workspace: --workspace is required"
[[ -n "$version" ]] || nyann::die "release-workspace: --version is required"
nyann::assert_path_under_target "$target" "$target/$workspace" "--workspace" >/dev/null

if [[ -n "$kind" ]]; then
  case "$kind" in
    module|chart|stack|overlay|role|playbook) ;;
    *) nyann::die "release-workspace: --kind must be one of module|chart|stack|overlay|role|playbook: got '$kind'" ;;
  esac
fi

ws_name=$(basename "$workspace")
# Prefer the unit's declared name (from iac.units[].name) for chart tags so an
# umbrella chart whose dir != chart name still tags by chart name; fall back to
# the path basename.
[[ -n "$unit_name" ]] || unit_name="$ws_name"

# --- per-unit tag prefix ------------------------------------------------------
# Default (no --kind): code-workspace convention `<basename>@<version>` —
# byte-for-byte unchanged. With --kind: tool-idiomatic, COLLISION-SAFE prefix.
# An explicit --tag-prefix always wins (caller takes responsibility).
if ! $tag_prefix_explicit || [[ -z "$tag_prefix" ]]; then
  case "$kind" in
    chart)
      # Helm convention: `<chart-name>-<version>` (e.g. app-0.4.0).
      tag_prefix="${unit_name}-"
      ;;
    module|stack|overlay|role|playbook)
      # Path-scoped: `<unit-path>/v<version>` (e.g. modules/vpc/v1.3.0). The
      # path prefix structurally guarantees no collision with a repo-wide
      # `vX.Y.Z` — they share no leading namespace.
      tag_prefix="${workspace%/}/v"
      ;;
    "")
      # Code workspace — unchanged v1.11.0 default.
      tag_prefix="${ws_name}@"
      ;;
  esac
fi
tag="${tag_prefix}${version}"

# A tag (or its prefix) must never start with '-': git would parse it as an
# option (e.g. in `git tag --list "<prefix>*"`), aborting uncleanly with rc
# 129 under errexit. Unit names/paths come from detection (e.g. a Helm
# Chart.yaml `name: -foo`), which can carry a leading dash even though the
# profile schema forbids it — reject cleanly before any git call.
if [[ "$tag" == -* ]]; then
  nyann::die "release-workspace: tag '$tag' starts with '-' (git would parse it as an option); rename the unit"
fi

# A tag must not contain shell-glob metacharacters (* ? [). The tag (via its
# prefix) is spliced into `git tag --list "<prefix>*"` patterns below: a name
# like `app*` yields the pattern `app**` which FALSE-MATCHES unrelated tags
# (picking a wrong from-ref -> silent noop), and `[` opens a never-closed
# bracket class making the pattern undefined. Names/paths come from detection
# (a Helm Chart.yaml `name:`, a stack filename) and the profile schema forbids
# these chars, but a malformed descriptor could carry them — reject cleanly
# before any git call rather than mis-glob. The leading-dash guard above only
# catches '-'; this covers the glob metachars.
if [[ "$tag" == *[*?[]* ]]; then
  nyann::die "release-workspace: tag '$tag' contains a shell-glob metacharacter (* ? [); these break the tag-list globs used to find the last tag — rename the unit"
fi

# Collision guard: a per-unit tag must NEVER equal a repo-wide release tag
# `vX.Y.Z`. The path-scoped / chart-name prefixes make this structurally
# impossible, but guard explicitly so a hand-passed --tag-prefix that collapses
# to a bare `vX.Y.Z` is rejected before any mutation. (`v` is the repo-wide
# default tag_prefix in release.sh.)
if [[ -n "$kind" && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  nyann::die "release-workspace: unit tag '$tag' collides with the repo-wide release tag namespace (vX.Y.Z); use a path- or name-scoped --tag-prefix"
fi

if git -C "$target" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  nyann::die "release-workspace: tag $tag already exists"
fi

# Find the last tag for this workspace. Anchor the glob to a DIGIT after the
# prefix (`<prefix>[0-9]*`, not `<prefix>*`): a SemVer version always starts
# with a digit, so this matches THIS unit's own version tags only. The bare
# `<prefix>*` for a chart prefix `app-` also matched a SIBLING chart's tags —
# `app-worker-2.0.0` — picking a wrong from-ref and silently producing a noop
# (the app change since `app-1.0.0` looked empty against the worker baseline).
# Anchoring is safe for every convention because the version directly follows
# the prefix in all of them: chart `app-` -> `app-[0-9]*`, module/stack
# `<path>/v` -> `<path>/v[0-9]*`, code `<name>@` -> `<name>@[0-9]*`.
last_tag=$(git -C "$target" -c versionsort.suffix=- tag --list --sort=-v:refname -- "${tag_prefix}[0-9]*" 2>/dev/null | head -n1)
if [[ -n "$last_tag" ]]; then
  from_ref="$last_tag"
else
  from_ref=$(git -C "$target" rev-list --max-parents=0 HEAD 2>/dev/null | head -n1)
fi

# Collect workspace-scoped commits (pass --kind through for IaC units)
commits_json=$("${_script_dir}/detect-workspace-changes.sh" \
  --target "$target" --workspace "$workspace" --from "$from_ref" \
  ${scope_csv:+--scopes "$scope_csv"} \
  ${kind:+--kind "$kind"})

# unit_kind fragment: present only for IaC units, so a code-workspace result
# stays byte-for-byte identical to v1.11.0.
if [[ -n "$kind" ]]; then
  kind_obj=$(jq -n --arg k "$kind" '{unit_kind:$k}')
else
  kind_obj='{}'
fi

n_commits=$(jq 'length' <<<"$commits_json")
if (( n_commits == 0 )); then
  jq -n --arg ws "$workspace" --arg version "$version" --arg tag "$tag" --arg from "$from_ref" \
    --argjson kind_obj "$kind_obj" \
    '{workspace:$ws, version:$version, tag:$tag, from:$from, commits:[], changelog_section:"", status:"noop"} + $kind_obj'
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
    --argjson kind_obj "$kind_obj" \
    '{workspace:$ws, version:$version, tag:$tag, from:$from, commits:$commits, changelog_section:$changelog, status:"preview", dry_run:true} + $kind_obj'
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
  --argjson kind_obj "$kind_obj" \
  '{workspace:$ws, version:$version, tag:$tag, from:$from, commits:$commits, changelog_section:$changelog, status:"released"} + $kind_obj'
