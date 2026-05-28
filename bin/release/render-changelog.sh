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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       version="${2:-}"; shift 2 ;;
    --version=*)     version="${1#--version=}"; shift ;;
    --commits-file)  commits_file="${2:-}"; shift 2 ;;
    --commits-file=*) commits_file="${1#--commits-file=}"; shift ;;
    -h|--help)       sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "render-changelog: unknown argument: $1" ;;
  esac
done

[[ -n "$version" ]] || nyann::die "render-changelog: --version is required"

date_str=$(date +%Y-%m-%d)

input_source="/dev/stdin"
if [[ -n "$commits_file" ]]; then
  [[ -f "$commits_file" ]] || nyann::die "render-changelog: --commits-file not found: $commits_file"
  input_source="$commits_file"
fi

jq -r --arg version "$version" --arg date "$date_str" '
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
' < "$input_source"
