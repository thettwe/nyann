#!/usr/bin/env bash
# Detector: version lag (severity medium). Surfaces a Helm chart's
# `appVersion` (the version of the app the chart deploys) lagging behind the
# repo's latest git tag — a sign the chart was not bumped with the release.
#
# Reuses the docs-drift version-ref semver machinery (v-prefix + pre-release
# suffix stripping, numeric semver compare). Skips entirely when there are no
# git tags (nothing to compare against).
#
# Usage: version-lag.sh --target <dir> --file <relpath> [--latest-tag <vX.Y.Z>]
# Emits NDJSON Finding objects on stdout. Exits 0 on any guard failure.

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
abs="$target/$file"
[[ -f "$abs" ]] || exit 0

# Only Helm Chart.yaml carries appVersion.
base="$(basename "$file")"
[[ "$base" == "Chart.yaml" ]] || exit 0

if [[ -z "$latest_tag" ]]; then
  latest_tag=$( cd "$target" && git describe --tags --abbrev=0 2>/dev/null || echo "" )
fi
# Skip when no git tags — there is no release line to lag behind.
[[ -n "$latest_tag" ]] || exit 0

# --- semver machinery (mirrors docs-drift/version-refs.sh) -------------------
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

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  case "$line" in *'# drift-ignore'*|*'<!-- drift-ignore -->'*) continue ;; esac
  # appVersion: "1.2.0"  /  appVersion: 1.2.0
  if [[ "$line" =~ ^[[:space:]]*appVersion:[[:space:]]*[\"\']?([0-9]+\.[0-9]+(\.[0-9]+)?)[\"\']? ]]; then
    app="${BASH_REMATCH[1]}"
    if semver_lt "$app" "$latest_clean"; then
      msg="Helm appVersion ${app} lags the latest git tag ${latest_tag}"
      jq -n --arg kind "version-lag" \
            --arg file "$file" \
            --argjson line "$lineno" \
            --arg severity "medium" \
            --arg message "$msg" \
            --arg current "$app" \
            --arg expected "${latest_clean}" \
            --arg hint "bump appVersion to ${latest_clean} when the app is released (or wrap with '# drift-ignore')" \
            '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, expected:$expected, fix_hint:$hint}'
    fi
  fi
done < "$abs"

exit 0
