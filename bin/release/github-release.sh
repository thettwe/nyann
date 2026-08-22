#!/usr/bin/env bash
# github-release.sh — create a GitHub release for a pushed tag.
#
# Usage:
#   github-release.sh --tag <tag>
#                     [--changelog-block <text>]
#                     [--is-prerelease]
#                     [--gh <path>]
#                     [--target <repo>] [--profile <path>]
#                     [--syft <path>]
#
# Output (JSON on stdout):
#   { "outcome": "created"|"skipped"|"failed", ... }
#   With --profile and security.sbom.attach_to_release enabled, a created
#   release also carries `sbom: {outcome: attached|skipped|failed, ...}` —
#   the SBOM is generated from the working tree (== the tagged tree at
#   release time) via the syft CLI and uploaded as a release asset.
#   Soft-skips (with a next_steps[] hint) when syft is absent: a release
#   never blocks on posture tooling.
#
# Exit codes:
#   0 — release created or soft-skipped (SBOM problems never change this)
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
target="$PWD"
profile_path=""
syft_bin="syft"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)              tag="${2:-}"; shift 2 ;;
    --tag=*)            tag="${1#--tag=}"; shift ;;
    --changelog-block)  changelog_block="${2:-}"; shift 2 ;;
    --changelog-block=*) changelog_block="${1#--changelog-block=}"; shift ;;
    --is-prerelease)    is_prerelease=true; shift ;;
    --gh)               gh_bin="${2:-}"; shift 2 ;;
    --gh=*)             gh_bin="${1#--gh=}"; shift ;;
    --target)           target="${2:-}"; shift 2 ;;
    --target=*)         target="${1#--target=}"; shift ;;
    --profile)          profile_path="${2:-}"; shift 2 ;;
    --profile=*)        profile_path="${1#--profile=}"; shift ;;
    --syft)             syft_bin="${2:-}"; shift 2 ;;
    --syft=*)           syft_bin="${1#--syft=}"; shift ;;
    --tag-not-pushed)   tag_pushed=false; shift ;;
    -h|--help)          sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# attach_sbom — generate an SBOM from the working tree (== the tagged tree
# at release time) and upload it as a release asset. Sets sbom_json. Never
# fails the release: posture tooling problems are soft outcomes + hints.
sbom_json='{"outcome":"disabled"}'
attach_sbom() {
  local want fmt syft_fmt sbom_file sbom_dir
  [[ -n "$profile_path" && -f "$profile_path" ]] || return 0
  # NB: `.attach_to_release // true` would be wrong — jq's `//` replaces
  # false AS WELL AS null, so an explicit false would read as true. The
  # default-when-absent must compare against null explicitly.
  want=$(jq -r 'if (.security.sbom.enabled == true) and (.security.sbom.attach_to_release != false) then "yes" else "no" end' "$profile_path" 2>/dev/null || echo no)
  [[ "$want" == "yes" ]] || return 0
  fmt=$(jq -r '.security.sbom.format // "cyclonedx"' "$profile_path" 2>/dev/null || echo cyclonedx)
  case "$fmt" in
    spdx) syft_fmt="spdx-json" ;;
    *)    fmt="cyclonedx"; syft_fmt="cyclonedx-json" ;;
  esac
  if ! command -v "$syft_bin" >/dev/null 2>&1; then
    nyann::warn "github-release: security.sbom.attach_to_release is on but syft is not installed — skipping the SBOM asset"
    _add_step "syft \"dir:$target\" -o ${syft_fmt}=sbom.${fmt}.json && $gh_bin release upload $tag sbom.${fmt}.json   # install syft, then attach the SBOM manually"
    sbom_json=$(jq -n '{outcome:"skipped", skipped_reason:"syft-not-installed"}')
    return 0
  fi
  sbom_dir=$(mktemp -d -t nyann-sbom.XXXXXX)
  sbom_file="${sbom_dir}/sbom.${fmt}.json"
  if ! "$syft_bin" "dir:$target" -o "${syft_fmt}=${sbom_file}" >/dev/null 2>&1; then
    nyann::warn "github-release: syft failed to generate the SBOM — release keeps going without the asset"
    sbom_json=$(jq -n '{outcome:"failed", error:"syft-generation-failed"}')
    rm -rf "$sbom_dir"
    return 0
  fi
  if "$gh_bin" release upload "$tag" "$sbom_file" >/dev/null 2>&1; then
    nyann::log "github-release: attached sbom.${fmt}.json to $tag"
    sbom_json=$(jq -n --arg a "sbom.${fmt}.json" --arg f "$fmt" \
      '{outcome:"attached", asset:$a, format:$f}')
  else
    nyann::warn "github-release: SBOM upload failed — release keeps going without the asset"
    _add_step "$gh_bin release upload $tag $sbom_file   # re-attach the generated SBOM"
    sbom_json=$(jq -n '{outcome:"failed", error:"upload-failed"}')
  fi
  rm -rf "$sbom_dir"
  return 0
}

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
  attach_sbom
  if [[ -n "$gh_url" ]]; then
    jq -n --arg url "$gh_url" --argjson pre "$is_prerelease" --argjson next_steps "$next_steps_json" \
      --argjson sbom "$sbom_json" \
      '{outcome:"created", url:$url, prerelease:$pre, sbom:$sbom, next_steps:$next_steps}'
  else
    jq -n --argjson pre "$is_prerelease" --argjson next_steps "$next_steps_json" \
      --argjson sbom "$sbom_json" \
      '{outcome:"created", prerelease:$pre, sbom:$sbom, next_steps:$next_steps}'
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
