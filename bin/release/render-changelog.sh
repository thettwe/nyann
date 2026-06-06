#!/usr/bin/env bash
# render-changelog.sh — render a Conventional Commits JSON array into a
# Markdown changelog block.
#
# Usage:
#   render-changelog.sh --version <x.y.z> [--commits-file <path>]
#   echo "$commits_json" | render-changelog.sh --version <x.y.z>
#
# Output (plain text on stdout):
#   ## [x.y.z] — YYYY-MM-DD
#   ### Features
#   - **scope**: subject (sha7)
#   ...
#
#   [x.y.z]: https://github.com/<owner>/<repo>/releases/tag/vx.y.z
#
# The trailing line is a Markdown link-reference definition for the `## [x.y.z]`
# header so the version renders as a clickable link on GitHub. The repo slug is
# derived from the `origin` remote (override with --repo-url). When the slug
# can't be resolved, the definition is omitted (the rest of the block still
# renders). Markdown resolves reference definitions regardless of position, so
# the def is valid even though release.sh prepends this block to the top of the
# file rather than appending it at the bottom.
#
# Exit codes:
#   0 — rendered
#   2 — bad arguments

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

version=""
commits_file=""
repo_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       version="${2:-}"; shift 2 ;;
    --version=*)     version="${1#--version=}"; shift ;;
    --commits-file)  commits_file="${2:-}"; shift 2 ;;
    --commits-file=*) commits_file="${1#--commits-file=}"; shift ;;
    --repo-url)      repo_url="${2:-}"; shift 2 ;;
    --repo-url=*)    repo_url="${1#--repo-url=}"; shift ;;
    -h|--help)       sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "render-changelog: unknown argument: $1" ;;
  esac
done

[[ -n "$version" ]] || nyann::die "render-changelog: --version is required"

date_str=$(date +%Y-%m-%d)

# Derive the GitHub repo slug (owner/name) for the link-reference definition.
# Prefer an explicit --repo-url; otherwise read the `origin` remote. Handles
# both SSH (git@github.com:owner/repo.git) and HTTPS
# (https://github.com/owner/repo.git) forms, with or without a trailing `.git`.
repo_slug=""
if [[ -z "$repo_url" ]]; then
  repo_url=$(git remote get-url origin 2>/dev/null || true)
fi
if [[ -n "$repo_url" ]]; then
  _slug="$repo_url"
  _slug="${_slug#git@github.com:}"
  _slug="${_slug#https://github.com/}"
  _slug="${_slug#http://github.com/}"
  _slug="${_slug#ssh://git@github.com/}"
  _slug="${_slug%.git}"
  # Only accept a clean owner/repo shape; anything else (non-GitHub remote,
  # unexpected URL form) leaves repo_slug empty so the def is simply omitted.
  if [[ "$_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    repo_slug="$_slug"
  fi
fi

input_source="/dev/stdin"
if [[ -n "$commits_file" ]]; then
  [[ -f "$commits_file" ]] || nyann::die "render-changelog: --commits-file not found: $commits_file"
  input_source="$commits_file"
fi

rendered=$(jq -r --arg version "$version" --arg date "$date_str" '
  def fmt_entry: "- " + (if .scope != "" then "**" + .scope + "**: " else "" end) + .subject + " (" + (.sha[0:7]) + ")";
  def section($heading; $entries):
    if ($entries | length) == 0 then ""
    else "### " + $heading + "\n\n" + ([$entries[] | fmt_entry] | join("\n")) + "\n\n"
    end;
  ["feat","fix","perf","refactor","docs","test","build","ci","chore"] as $known |
  "## [" + $version + "] — " + $date + "\n\n" +
  section("⚠️ Breaking changes"; [.[] | select(.breaking == true)]) +
  section("Features";    [.[] | select(.breaking == false and .type == "feat")]) +
  section("Fixes";       [.[] | select(.breaking == false and .type == "fix")]) +
  section("Performance"; [.[] | select(.breaking == false and .type == "perf")]) +
  section("Refactors";   [.[] | select(.breaking == false and .type == "refactor")]) +
  section("Docs";        [.[] | select(.breaking == false and .type == "docs")]) +
  section("Tests";       [.[] | select(.breaking == false and .type == "test")]) +
  section("Build";       [.[] | select(.breaking == false and .type == "build")]) +
  section("CI";          [.[] | select(.breaking == false and .type == "ci")]) +
  section("Chores";      [.[] | select(.breaking == false and .type == "chore")]) +
  section("Other"; [.[] | select(.breaking == false) | select(.type as $t | $t == "" or ($known | index($t) == null))])
' < "$input_source")

# Emit the body, then the link-reference definition for the version header so it
# renders as a clickable link on GitHub (matches the existing defs at the bottom
# of CHANGELOG.md). Skipped when the repo slug couldn't be resolved.
# Command substitution stripped the block's trailing newlines, so re-add a
# blank line to keep the section spacing the renderer produced (and to separate
# the body from the link def below).
printf '%s\n\n' "$rendered"
if [[ -n "$repo_slug" ]]; then
  printf '[%s]: https://github.com/%s/releases/tag/v%s\n\n' "$version" "$repo_slug" "$version"
fi
