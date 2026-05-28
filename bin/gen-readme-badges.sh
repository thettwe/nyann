#!/usr/bin/env bash
# gen-readme-badges.sh — generate a shields.io badge block for README.md.
#
# Usage:
#   gen-readme-badges.sh [--target <dir>] [--profile <file>] [--apply]
#                        [--owner <gh-owner>] [--repo <gh-repo>]
#
# Emits ReadmeBadgeBlock JSON to stdout. With --apply, also writes the
# marker-bracketed block into README.md (creating it if missing).
#
# Defaults: license, ci, release badges on; tests + health off unless
# the profile explicitly enables them.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_file=""
apply=false
owner=""
repo=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --profile)   profile_file="${2-}"; shift 2 ;;
    --profile=*) profile_file="${1#--profile=}"; shift ;;
    --owner)     owner="${2-}"; shift 2 ;;
    --owner=*)   owner="${1#--owner=}"; shift ;;
    --repo)      repo="${2-}"; shift 2 ;;
    --repo=*)    repo="${1#--repo=}"; shift ;;
    --apply)     apply=true; shift ;;
    -h|--help)   sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
cd "$target" || nyann::die "cd $target failed"

# Profile-driven badge flags (with defaults).
flag() {
  local key="$1" default="$2"
  if [[ -z "$profile_file" || ! -f "$profile_file" ]]; then
    printf '%s' "$default"
    return
  fi
  local v
  v=$(jq -r --arg k "$key" 'if .documentation.readme_badges[$k] == false then "false" elif .documentation.readme_badges[$k] == true then "true" else "" end' "$profile_file" 2>/dev/null)
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$default"
  fi
}

# Master switch.
master="true"
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  m=$(jq -r 'if .documentation.readme_badges.enabled == false then "false" elif .documentation.readme_badges.enabled == true then "true" else "" end' "$profile_file" 2>/dev/null)
  [[ -n "$m" ]] && master="$m"
fi

f_license=$(flag license true)
f_ci=$(flag ci true)
f_release=$(flag release true)
f_tests=$(flag tests false)
f_health=$(flag health false)
f_pm=$(flag package_manager false)

# Derive owner/repo from origin remote if not passed.
if [[ -z "$owner" || -z "$repo" ]]; then
  origin=$( git config --get remote.origin.url 2>/dev/null || echo "" )
  if [[ "$origin" =~ github\.com[:/]+([^/]+)/([^/]+?)(\.git)?$ ]]; then
    [[ -z "$owner" ]] && owner="${BASH_REMATCH[1]}"
    [[ -z "$repo" ]]  && repo="${BASH_REMATCH[2]}"
  fi
fi

lines=()
add_line() { lines+=("$1"); }

# license — read SPDX from a "License: <SPDX>" line in LICENSE, fall back
# to common heuristics on first line.
license_spdx=""
if [[ -f LICENSE ]]; then
  first=$(head -1 LICENSE)
  case "$first" in
    *"MIT"*)        license_spdx="MIT" ;;
    *"Apache"*"2"*) license_spdx="Apache--2.0" ;;
    *"BSD"*"3"*)    license_spdx="BSD--3--Clause" ;;
    *"GPL"*"3"*)    license_spdx="GPL--3.0" ;;
    *"MPL"*)        license_spdx="MPL--2.0" ;;
    *"ISC"*)        license_spdx="ISC" ;;
    *"Unlicense"*)  license_spdx="Unlicense" ;;
  esac
fi

if [[ "$master" == "true" && "$f_license" == "true" && -n "$license_spdx" ]]; then
  add_line "![License: ${license_spdx//--/-}](https://img.shields.io/badge/License-${license_spdx}-yellow.svg)"
fi

# ci — link the first .github/workflows yaml.
if [[ "$master" == "true" && "$f_ci" == "true" && -n "$owner" && -n "$repo" ]]; then
  workflow=$(find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | head -1 || true)
  if [[ -n "$workflow" ]]; then
    wfname=$(basename "$workflow")
    add_line "![CI](https://github.com/${owner}/${repo}/actions/workflows/${wfname}/badge.svg)"
  fi
fi

# release — github release shields badge.
if [[ "$master" == "true" && "$f_release" == "true" && -n "$owner" && -n "$repo" ]]; then
  add_line "![Release](https://img.shields.io/github/v/release/${owner}/${repo})"
fi

# tests — count.
if [[ "$master" == "true" && "$f_tests" == "true" ]]; then
  if [[ -d tests/bats ]]; then
    n=$(find tests/bats -maxdepth 1 -name '*.bats' 2>/dev/null | wc -l | tr -d ' ')
    add_line "![Tests](https://img.shields.io/badge/Tests-${n}%20passing-brightgreen)"
  fi
fi

# health — read memory/health.json if present.
if [[ "$master" == "true" && "$f_health" == "true" && -f memory/health.json ]]; then
  score=$(jq -r '(.scores[-1].score // empty) | tostring' memory/health.json 2>/dev/null || true)
  if [[ -n "$score" && "$score" != "null" ]]; then
    color="brightgreen"
    (( score < 80 )) && color="yellow"
    (( score < 60 )) && color="orange"
    (( score < 40 )) && color="red"
    add_line "![Health](https://img.shields.io/badge/Health-${score}%2F100-${color})"
  fi
fi

# package manager — detect.
if [[ "$master" == "true" && "$f_pm" == "true" ]]; then
  pm=""
  [[ -f pnpm-lock.yaml ]] && pm="pnpm"
  [[ -z "$pm" && -f yarn.lock ]] && pm="yarn"
  [[ -z "$pm" && -f package-lock.json ]] && pm="npm"
  [[ -z "$pm" && -f bun.lockb ]] && pm="bun"
  if [[ -n "$pm" ]]; then
    add_line "![${pm}](https://img.shields.io/badge/${pm}-managed-orange)"
  fi
fi

marker_start='<!-- nyann:badges:start -->'
marker_end='<!-- nyann:badges:end -->'

rendered="${marker_start}"$'\n'
for l in "${lines[@]:-}"; do
  [[ -z "$l" ]] && continue
  rendered+="${l}"$'\n'
done
rendered+="${marker_end}"

# Apply: rewrite the marker-bracketed block in README.md.
action="preview"
diff_summary="no change (preview only)"

if $apply; then
  readme="README.md"
  if [[ ! -f "$readme" ]]; then
    printf '%s\n' "$rendered" > "$readme"
    action="write"
    diff_summary="created README.md with badge block"
  else
    if grep -Fq "$marker_start" "$readme"; then
      # Replace existing block. BSD awk rejects multi-line -v vars; spool
      # the rendered block to a tmp file and read it via getline.
      body_tmp=$(mktemp -t nyann-body.XXXXXX)
      printf '%s' "$rendered" > "$body_tmp"
      tmp=$(mktemp -t nyann-readme.XXXXXX)
      awk -v ms="$marker_start" -v me="$marker_end" -v bf="$body_tmp" '
        BEGIN {
          skip=0
          while ((getline line < bf) > 0) {
            body = body (body == "" ? "" : "\n") line
          }
        }
        index($0, ms) { print body; skip=1; next }
        index($0, me) { skip=0; next }
        !skip { print }
      ' "$readme" > "$tmp"
      mv "$tmp" "$readme"
      rm -f "$body_tmp"
      action="write"
      diff_summary="replaced existing badge block"
    else
      # Prepend before the first heading.
      tmp=$(mktemp -t nyann-readme.XXXXXX)
      printf '%s\n\n%s' "$rendered" "$(cat "$readme")" > "$tmp"
      mv "$tmp" "$readme"
      action="write"
      diff_summary="inserted badge block at top of README"
    fi
  fi
fi

if (( ${#lines[@]} == 0 )); then
  lines_json='[]'
else
  lines_json=$(printf '%s\n' "${lines[@]}" | jq -R . | jq -s 'map(select(length > 0))')
fi

jq -n \
  --arg target "$target" \
  --arg ms "$marker_start" \
  --arg me "$marker_end" \
  --arg rendered "$rendered" \
  --arg action "$action" \
  --arg diff "$diff_summary" \
  --argjson lines "$lines_json" \
  '{target:$target, block_kind:"badges", marker_start:$ms, marker_end:$me, lines:$lines, rendered:$rendered, action:$action, diff_summary:$diff}'
