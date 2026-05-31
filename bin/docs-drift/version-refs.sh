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
# Strip leading v and any pre-release/build suffix (e.g. v1.2.0-rc1 → 1.2.0)
# before comparison. Doc refs use the GA form `vX.Y.Z`; without stripping the
# suffix, the digit-only parse turns `0-rc1` into `01` and wrongly reports the
# GA release as older than its own release candidate.
latest_clean="${latest_tag#v}"
latest_clean="${latest_clean%%-*}"
latest_clean="${latest_clean%%+*}"

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
# Track fenced code blocks: example commands routinely pin to arbitrary
# versions (`--pin-ref v1.0.0`) that are illustrative, not stale claims —
# flagging them is pure noise (mirrors file-refs.sh fence handling).
in_fence=0
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  case "$line" in
    '```'*|'~~~'*)
      in_fence=$((1 - in_fence))
      continue
      ;;
  esac
  (( in_fence )) && continue
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
    # Skip explicitly historical references: `pre-v1.6.0`, `post-v2.0.0`,
    # `since v1.0.0` — these intentionally name an older version and are
    # not drift. Look at how the match appears in the surrounding line.
    case "$line" in
      *"pre-${match}"*|*"post-${match}"*|*"since ${match}"*|*"before ${match}"*|*"prior to ${match}"*) continue ;;
    esac
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
