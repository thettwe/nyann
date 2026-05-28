#!/usr/bin/env bash
# collect-commits.sh — parse Conventional Commits from a git log range.
#
# Usage:
#   collect-commits.sh --target <repo> --log-range <range>
#
# Output (JSON on stdout):
#   [ {sha, type, scope, subject, breaking}, ... ]
#
# Exit codes:
#   0 — commits collected (may be empty array)
#   2 — bad arguments

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

target="$PWD"
log_range=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="${2:-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --log-range)   log_range="${2:-}"; shift 2 ;;
    --log-range=*) log_range="${1#--log-range=}"; shift ;;
    -h|--help)     sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "collect-commits: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "collect-commits: --target must be a directory"
[[ -n "$log_range" ]] || nyann::die "collect-commits: --log-range is required"

commits_tsv=$(mktemp -t nyann-cc-commits.XXXXXX)
trap 'rm -f "$commits_tsv"' EXIT

cc_regex='^([a-z]+)(\([^)]+\))?(!?):[[:space:]](.*)$'
while IFS= read -r sha && IFS= read -r subject; do
  [[ -z "$sha" ]] && continue
  ctype=""; cscope=""; csubject="$subject"; breaking=false
  if [[ "$subject" =~ $cc_regex ]]; then
    ctype="${BASH_REMATCH[1]}"
    cscope="${BASH_REMATCH[2]}"
    cscope="${cscope#(}"
    cscope="${cscope%)}"
    [[ "${BASH_REMATCH[3]}" == "!" ]] && breaking=true
    csubject="${BASH_REMATCH[4]}"
  fi
  csubject_safe="${csubject//[$'\t\r\n']/ }"
  cscope_safe="${cscope//[$'\t\r\n']/ }"
  printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$ctype" "$cscope_safe" "$csubject_safe" "$breaking" >> "$commits_tsv"
done < <(git -C "$target" log --pretty=tformat:'%H%n%s' "$log_range" 2>/dev/null || true)

jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({sha:.[0], type:.[1], scope:.[2], subject:.[3], breaking:(.[4] == "true")})
' < "$commits_tsv"
