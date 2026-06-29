#!/usr/bin/env bash
# detect-workspace-changes.sh — list CC-parsed commits scoped to a workspace.
#
# Usage:
#   detect-workspace-changes.sh --target <repo> --workspace <path>
#                               --from <ref> [--scopes <csv>] [--kind <kind>]
#
# A "workspace" here is any releasable unit — a code package (package.json /
# Cargo.toml monorepo) OR an IaC unit (a Helm chart, a terraform module, a
# stack/overlay/role/playbook, from the descriptor's iac.units[]). The path-diff
# below treats every unit identically: a unit's path IS its workspace path.
#
# A commit counts toward this unit if:
#   - Any of its changed files live under <workspace>/ (git log -- <path>), OR
#   - Its CC scope matches one of --scopes (e.g. feat(core): → "core")
#
# --kind is accepted for IaC units (module|chart|stack|overlay|role|playbook).
# It does not change change-detection (paths diff identically) — it is plumbed
# so release-workspace.sh can carry the unit kind through to its result. A code
# workspace omits --kind and is unaffected.
#
# Output: same JSON array as collect-commits.sh
#   [ {sha, type, scope, subject, breaking}, ... ]

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

target="$PWD"
workspace=""
from_ref=""
scope_csv=""
kind=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="${2:-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --workspace)   workspace="${2:-}"; shift 2 ;;
    --workspace=*) workspace="${1#--workspace=}"; shift ;;
    --from)        from_ref="${2:-}"; shift 2 ;;
    --from=*)      from_ref="${1#--from=}"; shift ;;
    --scopes)      scope_csv="${2:-}"; shift 2 ;;
    --scopes=*)    scope_csv="${1#--scopes=}"; shift ;;
    --kind)        kind="${2:-}"; shift 2 ;;
    --kind=*)      kind="${1#--kind=}"; shift ;;
    -h|--help)     sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "detect-workspace-changes: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "detect-workspace-changes: --target must be a directory"
[[ -n "$workspace" ]] || nyann::die "detect-workspace-changes: --workspace is required"
[[ -n "$from_ref" ]] || nyann::die "detect-workspace-changes: --from is required"

# --kind, when set, must be a known IaC unit kind. Validated (not consumed in
# diffing) so a typo surfaces here rather than silently flowing into a tag.
if [[ -n "$kind" ]]; then
  case "$kind" in
    module|chart|stack|overlay|role|playbook) ;;
    *) nyann::die "detect-workspace-changes: --kind must be one of module|chart|stack|overlay|role|playbook: got '$kind'" ;;
  esac
fi

log_range="${from_ref}..HEAD"

# Collect SHAs of commits that touch files under the workspace path
path_shas=$(git -C "$target" log --format='%H' "$log_range" -- "${workspace}/" 2>/dev/null || true)

# Collect SHAs of commits whose CC scope matches the workspace scopes
scope_shas=""
if [[ -n "$scope_csv" ]]; then
  IFS=',' read -ra scope_list <<<"$scope_csv"
  all_commits=$("${_script_dir}/collect-commits.sh" --target "$target" --log-range "$log_range")
  for scope in "${scope_list[@]}"; do
    [[ -z "$scope" ]] && continue
    matched=$(jq -r --arg s "$scope" '.[] | select(.scope == $s) | .sha' <<<"$all_commits")
    scope_shas="${scope_shas}${scope_shas:+$'\n'}${matched}"
  done
fi

# Merge and deduplicate SHAs
all_shas=$(printf '%s\n%s\n' "$path_shas" "$scope_shas" | sort -u | grep -v '^$' || true)

if [[ -z "$all_shas" ]]; then
  echo '[]'
  exit 0
fi

# Parse matching commits through CC parser
# Build a log range that includes only matching SHAs
cc_regex='^([a-z]+)(\([^)]+\))?(!?):[[:space:]](.*)$'
result_json='[]'

while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  subject=$(git -C "$target" log -1 --format='%s' "$sha" 2>/dev/null) || continue
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

  result_json=$(jq \
    --arg sha "$sha" --arg type "$ctype" --arg scope "$cscope_safe" \
    --arg subject "$csubject_safe" --argjson breaking "$breaking" \
    '. + [{sha:$sha, type:$type, scope:$scope, subject:$subject, breaking:$breaking}]' \
    <<<"$result_json")
done <<<"$all_shas"

echo "$result_json"
