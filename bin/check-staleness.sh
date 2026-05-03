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
# Schema validation upstream is best-effort (compute-drift falls back to
# `jq empty` when no JSON schema validator is installed). A profile that
# slipped through with `staleness_days: "abc"` would otherwise crash the
# trailing `--argjson threshold` jq call AFTER the per-file walk has
# already run, wasting work and emitting no structured report. Guard
# the threshold against non-positive-integer values up-front.
if ! [[ "$threshold" =~ ^[0-9]+$ ]] || (( threshold < 1 )); then
  nyann::warn "documentation.staleness_days must be a positive integer; got '$threshold' — staleness check disabled"
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

scanned=0
# Accumulate stale entries as TSV; collapses N per-file jq forks into 1
# at the end. On a profile with staleness enabled and many old docs,
# this is the dominant fork cost in the parallel doc subsystem dispatch.
stale_tsv=$(mktemp -t nyann-stale.XXXXXX)
trap 'rm -f "$stale_tsv"' EXIT

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
      # Unix filenames may legally contain tab/CR/LF. Sanitise before
      # serialising so a single weirdly-named doc can't corrupt the TSV
      # and abort the trailing jq reduce for the whole audit.
      rel_safe="${rel//[$'\t\r\n']/ }"
      printf '%s\t%s\n' "$rel_safe" "$days" >> "$stale_tsv"
    fi
  done < <(find "${scan_dirs[@]}" -type f -print0)
fi

stale=$(jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({path:.[0], last_modified_days_ago:(.[1]|tonumber)})' < "$stale_tsv")

jq -n \
  --argjson enabled true \
  --argjson threshold "$threshold" \
  --argjson scanned "$scanned" \
  --argjson stale "$stale" \
  '{ enabled: $enabled, threshold_days: $threshold, scanned: $scanned, stale: $stale }'
