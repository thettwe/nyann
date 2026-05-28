#!/usr/bin/env bash
# Detector: version-ref drift. Surfaces vX.Y.Z mentions older than the
# latest git tag in scanned files. Skips CHANGELOG.md (legitimate historical).
#
# Usage: version-refs.sh --target <dir> --file <relpath> [--latest-tag <vX.Y.Z>]
#
# Emits NDJSON Finding objects on stdout.

target=""; file=""; latest_tag=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --file)       file="${2-}"; shift 2 ;;
    --file=*)     file="${1#--file=}"; shift ;;
    --latest-tag) latest_tag="${2-}"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -n "$target" && -n "$file" ]] || exit 0

# Skip CHANGELOG — historical versions are legitimate there.
case "$file" in
  CHANGELOG.md|*/CHANGELOG.md|CHANGES.md|*/CHANGES.md) exit 0 ;;
esac

abs="$target/$file"
[[ -f "$abs" ]] || exit 0

if [[ -z "$latest_tag" ]]; then
  latest_tag=$( cd "$target" && git describe --tags --abbrev=0 2>/dev/null || echo "" )
fi
[[ -n "$latest_tag" ]] || exit 0
# Strip leading v if present for comparison.
latest_clean="${latest_tag#v}"

semver_lt() {
  # Returns 0 if $1 < $2 (numeric semver comparison).
  local a="$1" b="$2"
  local IFS='.'
  # shellcheck disable=SC2206
  local pa=($a) pb=($b)
  for i in 0 1 2; do
    local ai="${pa[$i]:-0}" bi="${pb[$i]:-0}"
    ai="${ai//[^0-9]/}"; bi="${bi//[^0-9]/}"
    ai=${ai:-0}; bi=${bi:-0}
    if (( ai < bi )); then return 0; fi
    if (( ai > bi )); then return 1; fi
  done
  return 1
}

# Walk lines containing semver, ignore lines containing drift-ignore marker.
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  case "$line" in
    *'<!-- drift-ignore -->'*) continue ;;
  esac
  # Skip inside HTML comment blocks (heuristic — single-line only).
  case "$line" in
    *'<!--'*'-->'*) continue ;;
  esac
  # Find v\d+\.\d+\.\d+ occurrences in the line.
  while read -r match; do
    [[ -z "$match" ]] && continue
    cur="${match#v}"
    if semver_lt "$cur" "$latest_clean"; then
      msg="version ref ${match} is older than latest tag ${latest_tag}"
      jq -n --arg kind "version-ref" \
            --arg file "$file" \
            --argjson line "$lineno" \
            --arg severity "high" \
            --arg message "$msg" \
            --arg current "$match" \
            --arg expected "$latest_tag" \
            --arg hint "update ${match} → ${latest_tag} (or wrap with <!-- drift-ignore -->)" \
            '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, expected:$expected, fix_hint:$hint}'
    fi
  done < <( printf '%s' "$line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' )
done < "$abs"
