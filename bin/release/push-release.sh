#!/usr/bin/env bash
# push-release.sh — push a release tag and optionally the release commit.
#
# Usage:
#   push-release.sh --target <repo> --tag <tag>
#                   [--strategy conventional-changelog|manual]
#                   [--is-prerelease]
#
# Output (JSON on stdout):
#   { "tag_pushed": true|false, "branch_pushed": true|false,
#     "pushed": true|false, "next_steps": [...] }
#
# Exit codes:
#   0 — all pushes succeeded (or no pushes needed)
#   3 — at least one push failed

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

target="$PWD"
tag=""
strategy="conventional-changelog"
is_prerelease=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         target="${2:-}"; shift 2 ;;
    --target=*)       target="${1#--target=}"; shift ;;
    --tag)            tag="${2:-}"; shift 2 ;;
    --tag=*)          tag="${1#--tag=}"; shift ;;
    --strategy)       strategy="${2:-}"; shift 2 ;;
    --strategy=*)     strategy="${1#--strategy=}"; shift ;;
    --is-prerelease)  is_prerelease=true; shift ;;
    -h|--help)        sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "push-release: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "push-release: --target must be a directory"
[[ -n "$tag" ]]    || nyann::die "push-release: --tag is required"

next_steps_json='[]'
_add_step() {
  next_steps_json=$(jq --arg s "$1" '. + [$s]' <<<"$next_steps_json")
}

git_safe_push=(-c protocol.allow=user -c protocol.ext.allow=never \
               -c protocol.file.allow=user \
               -c core.hooksPath=/dev/null)

tag_pushed=false
branch_pushed=true

push_err=$(mktemp -t nyann-release-push.XXXXXX)
trap 'rm -f "$push_err"' EXIT

nyann::log "push-release: pushing tag $tag to origin..."
if ! git "${git_safe_push[@]}" -C "$target" push origin -- "$tag" \
     2> >(tee "$push_err" >&2); then
  wait
  err=$(nyann::redact_url "$(cat "$push_err")")
  nyann::warn "push of tag $tag failed: $err"
  _add_step "git push origin $tag   # tag created locally; re-push after fixing the cause above"
else
  tag_pushed=true
fi
: > "$push_err"

if [[ "$strategy" == "conventional-changelog" ]] && ! $is_prerelease; then
  cur=$(git -C "$target" branch --show-current 2>/dev/null || echo "")
  if [[ -n "$cur" ]]; then
    nyann::log "push-release: pushing release commit on branch $cur to origin..."
    if ! git "${git_safe_push[@]}" -C "$target" push origin -- "$cur" \
         >/dev/null 2> >(tee "$push_err" >&2); then
      wait
      err=$(nyann::redact_url "$(cat "$push_err")")
      nyann::warn "push of branch $cur failed (tag $tag still pushed): $err"
      _add_step "git push origin $cur   # release commit is local-only; push after fixing the cause above"
      branch_pushed=false
    fi
  fi
fi

pushed=false
if $tag_pushed && $branch_pushed; then
  pushed=true
fi

jq -n \
  --argjson tag_pushed "$tag_pushed" \
  --argjson branch_pushed "$branch_pushed" \
  --argjson pushed "$pushed" \
  --argjson next_steps "$next_steps_json" \
  '{tag_pushed:$tag_pushed, branch_pushed:$branch_pushed, pushed:$pushed, next_steps:$next_steps}'

if ! $pushed; then
  exit 3
fi
