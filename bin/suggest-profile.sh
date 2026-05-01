#!/usr/bin/env bash
# suggest-profile.sh — suggest the best matching profile for a repo.
#
# Usage:
#   suggest-profile.sh --target <repo> [--plugin-root <dir>] [--user-root <dir>]
#
# Runs detect-stack.sh, then scores every available starter profile against
# the detected stack. Emits primary suggestions (for the main language) and
# secondary_suggestions (for each secondary language detected in multi-stack
# repos). Both arrays are ranked by confidence.
#
# Exit codes:
#   0 — suggestions emitted (may be empty if nothing matches)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
plugin_root="$(cd "${_script_dir}/.." && pwd)"
user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --plugin-root)   plugin_root="${2:-}"; shift 2 ;;
    --plugin-root=*) plugin_root="${1#--plugin-root=}"; shift ;;
    --user-root)     user_root="${2:-}"; shift 2 ;;
    --user-root=*)   user_root="${1#--user-root=}"; shift ;;
    -h|--help)       sed -n '3,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"

# --- detect stack -----------------------------------------------------------

stack_json=$("${_script_dir}/detect-stack.sh" --path "$target") \
  || nyann::die "detect-stack.sh failed"

detected_lang=$(jq -r '.primary_language // "unknown"' <<<"$stack_json")
detected_fw=$(jq -r '.framework // "null"' <<<"$stack_json")
detected_pm=$(jq -r '.package_manager // "null"' <<<"$stack_json")
detected_confidence=$(jq -r '.confidence // 0' <<<"$stack_json")
secondary_langs_json=$(jq -c '.secondary_languages // []' <<<"$stack_json")
is_monorepo=$(jq -r '.is_monorepo // false' <<<"$stack_json")

nyann::log "detected: lang=$detected_lang fw=$detected_fw pm=$detected_pm confidence=$detected_confidence"

secondary_count=$(jq 'length' <<<"$secondary_langs_json")
if (( secondary_count > 0 )); then
  nyann::log "secondary languages: $(jq -r 'join(", ")' <<<"$secondary_langs_json")"
fi

# --- scoring function -------------------------------------------------------
# score_profiles <match_lang> <match_fw> <match_pm>
# Reads all profiles and outputs a JSON array of matches.

score_profiles() {
  local match_lang="$1" match_fw="$2" match_pm="$3"
  local profiles_dir="$plugin_root/profiles"
  local acc='[]'

  _score_one() {
    local profile_path="$1"
    local name
    name=$(basename "$profile_path" .json)
    [[ "$name" == "_schema" ]] && return

    local p_lang p_fw p_pm score reasons
    p_lang=$(jq -r '.stack.primary_language // "unknown"' "$profile_path")
    p_fw=$(jq -r '.stack.framework // "null"' "$profile_path")
    p_pm=$(jq -r '.stack.package_manager // "null"' "$profile_path")
    score=0
    reasons='[]'

    # Language match (strongest signal).
    if [[ "$p_lang" == "$match_lang" && "$p_lang" != "unknown" ]]; then
      score=$((score + 50))
      reasons=$(jq --arg r "language match: $match_lang" '. + [$r]' <<<"$reasons")
    elif [[ "$p_lang" == "unknown" && "$match_lang" == "unknown" ]]; then
      score=$((score + 20))
      reasons=$(jq '. + ["both unknown language"]' <<<"$reasons")
    fi

    # JS ↔ TS affinity.
    if [[ "$score" -eq 0 ]]; then
      if { [[ "$match_lang" == "javascript" && "$p_lang" == "typescript" ]] \
        || [[ "$match_lang" == "typescript" && "$p_lang" == "javascript" ]]; }; then
        score=$((score + 35))
        reasons=$(jq --arg r "JS/TS affinity: $match_lang ≈ $p_lang" '. + [$r]' <<<"$reasons")
      fi
    fi

    # Framework match.
    if [[ "$p_fw" != "null" && "$match_fw" != "null" && "$p_fw" == "$match_fw" ]]; then
      score=$((score + 40))
      reasons=$(jq --arg r "framework match: $match_fw" '. + [$r]' <<<"$reasons")
    elif [[ "$p_fw" == "null" && "$match_fw" == "null" && "$score" -gt 0 ]]; then
      score=$((score + 5))
      reasons=$(jq '. + ["no framework (matches generic profile)"]' <<<"$reasons")
    fi

    # Package manager match (weak signal).
    if [[ "$p_pm" != "null" && "$match_pm" != "null" && "$p_pm" == "$match_pm" ]]; then
      score=$((score + 5))
      reasons=$(jq --arg r "package manager match: $match_pm" '. + [$r]' <<<"$reasons")
    fi

    (( score == 0 )) && return

    local confidence=$score
    (( confidence > 100 )) && confidence=100

    acc=$(jq \
      --arg name "$name" \
      --argjson confidence "$confidence" \
      --argjson reasons "$reasons" \
      '. + [{name: $name, confidence: $confidence, reasons: $reasons}]' <<<"$acc")
  }

  for f in "$profiles_dir"/*.json; do
    [[ -f "$f" ]] || continue
    _score_one "$f"
  done

  if [[ -d "$user_root/profiles" ]]; then
    for f in "$user_root/profiles"/*.json; do
      [[ -f "$f" ]] || continue
      _score_one "$f"
    done
  fi

  # Deduplicate by name, keep highest confidence per name.
  jq '
    group_by(.name) |
    map(sort_by(-.confidence) | .[0]) |
    sort_by(-.confidence)
  ' <<<"$acc"
}

# --- primary suggestions ----------------------------------------------------

primary_results=$(score_profiles "$detected_lang" "$detected_fw" "$detected_pm")

# --- secondary suggestions --------------------------------------------------
# For each secondary language, score profiles with that language and no
# framework (detect-stack doesn't report per-secondary-language frameworks).

secondary_results='[]'
if (( secondary_count > 0 )); then
  while IFS= read -r sec_lang; do
    [[ -z "$sec_lang" ]] && continue
    sec_matches=$(score_profiles "$sec_lang" "null" "null")
    sec_count=$(jq 'length' <<<"$sec_matches")
    if (( sec_count > 0 )); then
      secondary_results=$(jq \
        --arg lang "$sec_lang" \
        --argjson matches "$sec_matches" \
        '. + [{ language: $lang, suggestions: $matches }]' <<<"$secondary_results")
    fi
  done < <(jq -r '.[]' <<<"$secondary_langs_json")
fi

# --- emit output ------------------------------------------------------------

jq -n \
  --arg detected_language "$detected_lang" \
  --arg detected_framework "$detected_fw" \
  --arg detected_package_manager "$detected_pm" \
  --argjson detected_confidence "$detected_confidence" \
  --argjson is_monorepo "$is_monorepo" \
  --argjson secondary_languages "$secondary_langs_json" \
  --argjson suggestions "$primary_results" \
  --argjson secondary_suggestions "$secondary_results" \
  '{
    detected: {
      language: $detected_language,
      framework: (if $detected_framework == "null" then null else $detected_framework end),
      package_manager: (if $detected_package_manager == "null" then null else $detected_package_manager end),
      confidence: $detected_confidence,
      is_monorepo: $is_monorepo,
      secondary_languages: $secondary_languages
    },
    suggestions: $suggestions,
    secondary_suggestions: $secondary_suggestions
  }'
