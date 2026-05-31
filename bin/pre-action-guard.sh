#!/usr/bin/env bash
# pre-action-guard.sh — run all pre-flow guards and emit GuardResult JSON.
#
# Usage:
#   pre-action-guard.sh --flow <commit|pr|release|ship> [--target <dir>] [--base <branch>] [--profile <file>]
#
# Reads optional profile.guards.<flow> = [ { name, severity? }, ... ] to
# (a) restrict which guards run and (b) optionally promote an advisory
# guard to "confirm" or "critical" severity. Default: all built-in guards
# for the flow run at their built-in severity.
#
# Exit codes:
#   0   all guards passed (or only advisory warnings)
#   1   hard error (missing arg, unknown flow, jq missing)
#   3   one or more guards failed at "critical" severity
#   4   one or more guards failed at "confirm" severity (caller prompts)
#
# Output: GuardResult JSON on stdout (matches schemas/guard-result.schema.json).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

flow=""
target="$PWD"
base="main"
profile_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow)   flow="${2-}"; shift 2 ;;
    --flow=*) flow="${1#--flow=}"; shift ;;
    --target)   target="${2-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --base)   base="${2-}"; shift 2 ;;
    --base=*) base="${1#--base=}"; shift ;;
    --profile)   profile_file="${2-}"; shift 2 ;;
    --profile=*) profile_file="${1#--profile=}"; shift ;;
    -h|--help)   sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

case "$flow" in
  commit|pr|release|ship) ;;
  *) nyann::die "--flow must be one of commit|pr|release|ship (got: $flow)" ;;
esac

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"

# Per-flow built-in guard list. The order matters: dependencies first
# (e.g., staged files exist before scanning the staged diff).
case "$flow" in
  commit)  builtin_guards=( staged-files-exist merge-conflict-markers ) ;;
  pr)      builtin_guards=( branch-pushed wip-commits ) ;;
  release) builtin_guards=( clean-tree ) ;;
  ship)    builtin_guards=( branch-pushed wip-commits ) ;;
esac

# Read profile.guards.<flow> overrides (if profile passed and valid).
override_names=""
override_severities=""
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  override_names=$(jq -r --arg f "$flow" '.guards[$f] // [] | map(.name) | .[]' "$profile_file" 2>/dev/null || true)
  override_severities=$(jq -r --arg f "$flow" '.guards[$f] // [] | map("\(.name)=\(.severity // "")") | .[]' "$profile_file" 2>/dev/null || true)
fi

# Compose the effective guard list:
#  - If the profile declares any entries, use ONLY those (subset semantics).
#  - Otherwise, run all built-in guards.
effective_guards=()
if [[ -n "$override_names" ]]; then
  while IFS= read -r g; do
    [[ -n "$g" ]] && effective_guards+=("$g")
  done <<< "$override_names"
else
  effective_guards=("${builtin_guards[@]}")
fi

# Build a map name → promoted-severity (empty when no promotion).
declare -a sev_map=()
if [[ -n "$override_severities" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && sev_map+=("$line")
  done <<< "$override_severities"
fi

# Numeric rank for severity comparison (higher = more severe).
severity_rank() {
  case "$1" in
    critical) echo 3 ;;
    confirm)  echo 2 ;;
    advisory) echo 1 ;;
    *)        echo 0 ;;
  esac
}

resolve_promoted_severity() {
  local target_name="$1" entry n s
  # Guard against unbound-array dereference under `set -u` when no
  # promotions were declared.
  if (( ${#sev_map[@]} == 0 )); then
    printf ''
    return 0
  fi
  for entry in "${sev_map[@]}"; do
    n="${entry%%=*}"; s="${entry#*=}"
    if [[ "$n" == "$target_name" && -n "$s" ]]; then
      printf '%s' "$s"
      return 0
    fi
  done
  printf ''
}

# Run each guard, collect results.
tmp=$(mktemp -d -t nyann-guards.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

idx=0
for g in "${effective_guards[@]}"; do
  guard_script="${_script_dir}/guards/${g}.sh"
  if [[ ! -x "$guard_script" && ! -f "$guard_script" ]]; then
    jq -n --arg name "$g" \
      '{name:$name,pass:true,severity:"advisory",skipped:true,message:"guard not implemented — skipped"}' \
      > "$tmp/${idx}.json"
    idx=$((idx+1))
    continue
  fi
  # Each guard takes target, optional base. Capture stdout; ignore stderr.
  if ! bash "$guard_script" "$target" "$base" > "$tmp/${idx}.json" 2>/dev/null; then
    jq -n --arg name "$g" \
      '{name:$name,pass:false,severity:"advisory",skipped:true,message:"guard execution failed"}' \
      > "$tmp/${idx}.json"
  fi
  # Apply profile-promoted severity (advisory → confirm → critical; never
  # demote). Profiles can promote built-in advisories to confirm/critical,
  # but must never weaken a built-in critical/confirm — a misconfigured
  # profile shouldn't be able to silently disarm a hard block. Rank the
  # built-in vs requested severity and only write when strictly higher.
  promoted=$(resolve_promoted_severity "$g")
  if [[ -n "$promoted" ]]; then
    builtin_sev=$(jq -r '.severity // "advisory"' "$tmp/${idx}.json" 2>/dev/null || echo advisory)
    case "$promoted" in
      advisory|confirm|critical)
        if (( $(severity_rank "$promoted") > $(severity_rank "$builtin_sev") )); then
          jq --arg s "$promoted" '.severity = $s' "$tmp/${idx}.json" > "$tmp/${idx}.json.tmp" \
            && mv "$tmp/${idx}.json.tmp" "$tmp/${idx}.json"
        fi
        ;;
    esac
  fi
  idx=$((idx+1))
done

# Aggregate.
all_results=$(jq -s '.' "$tmp"/*.json 2>/dev/null || echo '[]')

# Determine overall pass + worst severity among failures.
worst="none"
fail_count=$(jq '[.[] | select(.pass == false and (.skipped // false) == false)] | length' <<<"$all_results")
if (( fail_count > 0 )); then
  for sev in critical confirm advisory; do
    n=$(jq --arg s "$sev" '[.[] | select(.pass == false and (.skipped // false) == false and .severity == $s)] | length' <<<"$all_results")
    if (( n > 0 )); then
      worst="$sev"
      break
    fi
  done
fi

pass=true
[[ "$worst" == "critical" || "$worst" == "confirm" ]] && pass=false

jq -n --arg flow "$flow" --argjson pass "$pass" --argjson guards "$all_results" \
  '{flow:$flow, pass:$pass, guards:$guards}'

case "$worst" in
  critical) exit 3 ;;
  confirm)  exit 4 ;;
  *)        exit 0 ;;
esac
