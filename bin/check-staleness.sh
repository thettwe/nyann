#!/usr/bin/env bash
# check-staleness.sh — flag docs/ + memory/ files older than the profile's
# staleness_days threshold.
#
# Usage: check-staleness.sh --target <repo> --profile <path>
#
# Behavior:
#   - Reads .documentation.staleness_days from the profile. Null/absent →
#     emit {enabled:false, stale:[]} and exit 0 (opt-in check).
#   - For each file under docs/ + memory/ (excluding paths in
#     templates/orphan-exclusions.txt + target's .nyann-ignore), compare
#     last-modified against today. When days ≥ threshold, add to stale[].
#
# Output: StalenessReport JSON
# { enabled, threshold_days, scanned, stale: [{path, last_modified_days_ago}] }

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
exclusions_path="${_script_dir}/../templates/orphan-exclusions.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --profile)         profile_path="${2:-}"; shift 2 ;;
    --profile=*)       profile_path="${1#--profile=}"; shift ;;
    --exclusions)      exclusions_path="${2:-}"; shift 2 ;;
    --exclusions=*)    exclusions_path="${1#--exclusions=}"; shift ;;
    -h|--help)         sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target is required"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile is required"
target="$(cd "$target" && pwd)"

threshold=$(jq -r '.documentation.staleness_days // empty' "$profile_path")
if [[ -z "$threshold" || "$threshold" == "null" ]]; then
  jq -n '{ enabled: false, threshold_days: null, scanned: 0, stale: [] }'
  exit 0
fi

# --- exclusions --------------------------------------------------------------

# shellcheck disable=SC2034  # populated by nyann::load_globs, read by nyann::is_excluded
exclusions=()
nyann::load_globs "$exclusions_path"
nyann::load_globs "$target/.nyann-ignore"

# --- walk --------------------------------------------------------------------

scan_dirs=()
[[ -d "$target/docs" ]]   && scan_dirs+=("$target/docs")
[[ -d "$target/memory" ]] && scan_dirs+=("$target/memory")

stale='[]'
scanned=0

if [[ ${#scan_dirs[@]} -gt 0 ]]; then
  now=$(date +%s)
  while IFS= read -r -d '' f; do
    rel="${f#"$target"/}"
    base="$(basename "$f")"
    nyann::is_excluded "$base" "$rel" && continue
    scanned=$((scanned + 1))

    if stat -f "%m" "$f" >/dev/null 2>&1; then
      mtime=$(stat -f "%m" "$f")
    else
      mtime=$(stat -c "%Y" "$f")
    fi
    days=$(( (now - mtime) / 86400 ))
    if (( days >= threshold )); then
      stale=$(jq --arg p "$rel" --argjson d "$days" \
        '. + [{ path: $p, last_modified_days_ago: $d }]' <<<"$stale")
    fi
  done < <(find "${scan_dirs[@]}" -type f -print0)
fi

jq -n \
  --argjson enabled true \
  --argjson threshold "$threshold" \
  --argjson scanned "$scanned" \
  --argjson stale "$stale" \
  '{ enabled: $enabled, threshold_days: $threshold, scanned: $scanned, stale: $stale }'
