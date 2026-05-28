#!/usr/bin/env bash
# github-release.sh — create a GitHub release for a pushed tag.
#
# Usage:
#   github-release.sh --tag <tag>
#                     [--changelog-block <text>]
#                     [--is-prerelease]
#                     [--gh <path>]
#
# Output (JSON on stdout):
#   { "outcome": "created"|"skipped"|"failed", ... }
#
# Exit codes:
#   0 — release created or soft-skipped
#   1 — gh release create failed (outcome still emitted)

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

tag=""
changelog_block=""
is_prerelease=false
gh_bin="gh"
tag_pushed=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)              tag="${2:-}"; shift 2 ;;
    --tag=*)            tag="${1#--tag=}"; shift ;;
    --changelog-block)  changelog_block="${2:-}"; shift 2 ;;
    --changelog-block=*) changelog_block="${1#--changelog-block=}"; shift ;;
    --is-prerelease)    is_prerelease=true; shift ;;
    --gh)               gh_bin="${2:-}"; shift 2 ;;
    --gh=*)             gh_bin="${1#--gh=}"; shift ;;
    --tag-not-pushed)   tag_pushed=false; shift ;;
    -h|--help)          sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "github-release: unknown argument: $1" ;;
  esac
done

[[ -n "$tag" ]] || nyann::die "github-release: --tag is required"

next_steps_json='[]'
_add_step() {
  next_steps_json=$(jq --arg s "$1" '. + [$s]' <<<"$next_steps_json")
}

if ! $tag_pushed; then
  nyann::warn "github-release: tag $tag wasn't pushed; skipping GitHub release creation"
  _add_step "git push origin $tag && gh release create $tag --title \"$tag\"   # push the tag first, then re-create the release"
  jq -n --argjson next_steps "$next_steps_json" \
    '{outcome:"skipped", skipped_reason:"tag-not-pushed"} + {next_steps:$next_steps}'
  exit 0
fi

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  _add_step "gh release create $tag --title \"$tag\" --notes-file <CHANGELOG-block>   # gh missing; install gh, then re-create the release manually"
  jq -n --argjson next_steps "$next_steps_json" \
    '{outcome:"skipped", skipped_reason:"gh-not-installed"} + {next_steps:$next_steps}'
  exit 0
fi

if ! "$gh_bin" auth status >/dev/null 2>&1; then
  _add_step "gh auth login && gh release create $tag --title \"$tag\" --notes-file <CHANGELOG-block>"
  jq -n --argjson next_steps "$next_steps_json" \
    '{outcome:"skipped", skipped_reason:"gh-not-authenticated"} + {next_steps:$next_steps}'
  exit 0
fi

notes_file=$(mktemp -t nyann-release-notes.XXXXXX)
trap 'rm -f "$notes_file"' EXIT

if [[ -n "$changelog_block" ]]; then
  printf '%s' "$changelog_block" > "$notes_file"
else
  printf '%s\n' "Release $tag." > "$notes_file"
fi

gh_args=(release create "$tag" --title "$tag" --notes-file "$notes_file")
if $is_prerelease; then
  gh_args+=(--prerelease)
fi

gh_create_err=$(mktemp -t nyann-gh-rel.XXXXXX)
trap 'rm -f "$notes_file" "$gh_create_err"' EXIT

nyann::log "github-release: creating release for $tag via gh..."
if gh_url=$("$gh_bin" "${gh_args[@]}" 2> >(tee "$gh_create_err" >&2)); then
  gh_url=$(printf '%s' "$gh_url" | tr -d '\r' \
    | grep -m1 -E '^https?://[^[:space:]]+/releases/tag/' || true)
  if [[ -n "$gh_url" ]]; then
    jq -n --arg url "$gh_url" --argjson pre "$is_prerelease" --argjson next_steps "$next_steps_json" \
      '{outcome:"created", url:$url, prerelease:$pre, next_steps:$next_steps}'
  else
    jq -n --argjson pre "$is_prerelease" --argjson next_steps "$next_steps_json" \
      '{outcome:"created", prerelease:$pre, next_steps:$next_steps}'
  fi
else
  wait
  err=$(nyann::redact_url "$(head -c 1000 "$gh_create_err" | tr '\n' ' ')")
  nyann::warn "github-release: gh release create failed: $err"
  _add_step "gh release create $tag --title \"$tag\" --notes-file <changelog-block>   # gh release create failed; re-run after fixing the cause above"
  jq -n --arg err "$err" --argjson pre "$is_prerelease" --argjson next_steps "$next_steps_json" \
    '{outcome:"failed", error:$err, prerelease:$pre, next_steps:$next_steps}'
  exit 1
fi
