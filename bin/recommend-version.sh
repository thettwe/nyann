#!/usr/bin/env bash
# recommend-version.sh — suggest the next semver version from commit history.
#
# Usage:
#   recommend-version.sh --target <repo>
#                        [--tag-prefix <prefix>]   # default: v
#                        [--from <ref>]             # default: latest tag matching prefix
#
# Walks commits since the last matching tag and applies Conventional Commits
# semver rules:
#   - Any breaking change (type!: subject OR BREAKING CHANGE footer) → major
#   - Any `feat` commit                                              → minor
#   - Everything else (fix, docs, chore, …)                          → patch
#
# Special case: when the current major is 0 (pre-1.0), breaking changes
# bump minor instead of major — standard semver §4 semantics.
#
# Output (JSON on stdout):
#   {
#     "status":       "ok" | "no-commits" | "no-tags",
#     "current":      "x.y.z" | null,
#     "recommended":  "x.y.z",
#     "bump":         "major" | "minor" | "patch" | "first",
#     "reason":       "human-readable summary",
#     "from":         "<ref>",
#     "counts":       { "breaking": N, "feat": N, "fix": N, "other": N, "total": N }
#   }
#
# Exit codes:
#   0 — recommendation emitted (including no-commits / no-tags)
#   1 — hard error (not a git repo, bad arguments)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
tag_prefix="v"
from_ref=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --tag-prefix)   tag_prefix="${2:-}"; shift 2 ;;
    --tag-prefix=*) tag_prefix="${1#--tag-prefix=}"; shift ;;
    --from)         from_ref="${2:-}"; shift 2 ;;
    --from=*)       from_ref="${1#--from=}"; shift ;;
    -h|--help)      sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- validate inputs ---------------------------------------------------------

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

if [[ -n "$tag_prefix" ]] && ! [[ "$tag_prefix" =~ ^[A-Za-z0-9._/-]*$ ]]; then
  nyann::die "--tag-prefix must contain only [A-Za-z0-9._/-]: got '$tag_prefix'"
fi

if [[ -n "$from_ref" ]] && ! nyann::valid_git_ref "$from_ref"; then
  nyann::die "--from must be a valid git ref: got '$from_ref'"
fi

# --- resolve from-ref and current version ------------------------------------

current_version=""
log_range=""

# Always resolve current version from tags, regardless of --from.
latest_tag=$(git -C "$target" tag --list "${tag_prefix}*" --sort=-v:refname | head -n1)
if [[ -n "$latest_tag" ]]; then
  current_version="${latest_tag#"$tag_prefix"}"
fi

if [[ -n "$from_ref" ]]; then
  log_range="${from_ref}..HEAD"
else
  if [[ -n "$latest_tag" ]]; then
    from_ref="$latest_tag"
    log_range="${from_ref}..HEAD"
  else
    from_ref="$(git -C "$target" rev-list --max-parents=0 HEAD 2>/dev/null | head -n1)"
    if [[ -z "$from_ref" ]]; then
      nyann::die "repository has no commits"
    fi
    log_range="HEAD"
  fi
fi

# --- collect and classify commits -------------------------------------------

count_breaking=0
count_feat=0
count_fix=0
count_other=0
count_total=0

cc_regex='^([a-z]+)(\([^)]+\))?(!?):[[:space:]](.*)$'
breaking_footer_regex='^BREAKING[ -]CHANGE:[[:space:]]'

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Separator between commits.
  if [[ "$line" == "---COMMIT---" ]]; then
    continue
  fi

  # Parse "SHA SUBJECT" on first line, then body lines follow.
  subject="${line#* }"
  count_total=$((count_total + 1))

  ctype=""
  breaking=false
  if [[ "$subject" =~ $cc_regex ]]; then
    ctype="${BASH_REMATCH[1]}"
    [[ "${BASH_REMATCH[3]}" == "!" ]] && breaking=true
  fi

  # Read body lines until next commit separator.
  while IFS= read -r bline; do
    [[ "$bline" == "---COMMIT---" ]] && break
    if ! $breaking && [[ "$bline" =~ $breaking_footer_regex ]]; then
      breaking=true
    fi
  done

  if $breaking; then
    count_breaking=$((count_breaking + 1))
  elif [[ "$ctype" == "feat" ]]; then
    count_feat=$((count_feat + 1))
  elif [[ "$ctype" == "fix" ]]; then
    count_fix=$((count_fix + 1))
  else
    count_other=$((count_other + 1))
  fi
done < <(git -C "$target" log --pretty=tformat:'%H %s%n%b%n---COMMIT---' "$log_range" 2>/dev/null || true)

# --- determine bump ----------------------------------------------------------

emit() {
  jq -n \
    --arg status "$1" \
    --arg current "$2" \
    --arg recommended "$3" \
    --arg bump "$4" \
    --arg reason "$5" \
    --arg from "$from_ref" \
    --argjson counts "{\"breaking\":$count_breaking,\"feat\":$count_feat,\"fix\":$count_fix,\"other\":$count_other,\"total\":$count_total}" \
    '{status:$status, current:(if $current == "" then null else $current end),
      recommended:$recommended, bump:$bump, reason:$reason,
      from:$from, counts:$counts}'
}

if [[ -z "$current_version" ]]; then
  emit "no-tags" "" "0.1.0" "first" "${count_total} commit(s), no prior tags; suggesting initial release"
  exit 0
fi

if (( count_total == 0 )); then
  emit "no-commits" "$current_version" "$current_version" "none" "no commits since $from_ref"
  exit 0
fi

# Parse current version into components.
# Strip any prerelease suffix for arithmetic.
base_version="${current_version%%-*}"
IFS='.' read -r cur_major cur_minor cur_patch <<< "$base_version"

if (( count_breaking > 0 )); then
  if (( cur_major == 0 )); then
    # Pre-1.0: breaking bumps minor per semver §4.
    new_version="0.$((cur_minor + 1)).0"
    bump="minor"
    reason="${count_breaking} breaking change(s) found (pre-1.0: bumps minor instead of major)"
  else
    new_version="$((cur_major + 1)).0.0"
    bump="major"
    reason="${count_breaking} breaking change(s) found"
  fi
elif (( count_feat > 0 )); then
  new_version="${cur_major}.$((cur_minor + 1)).0"
  bump="minor"
  reason="${count_feat} new feature(s) found"
else
  new_version="${cur_major}.${cur_minor}.$((cur_patch + 1))"
  bump="patch"
  if (( count_fix > 0 )); then
    reason="${count_fix} fix(es) found"
  else
    reason="${count_total} commit(s), no features or breaking changes"
  fi
fi

emit "ok" "$current_version" "$new_version" "$bump" "$reason"
