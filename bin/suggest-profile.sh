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
stack_file=""
plugin_root="$(cd "${_script_dir}/.." && pwd)"
user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --stack)         stack_file="${2:-}"; shift 2 ;;
    --stack=*)       stack_file="${1#--stack=}"; shift ;;
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
# Accept pre-computed StackDescriptor via --stack <file> to avoid redundant
# detect-stack.sh calls (e.g. bootstrap already ran detection in step 1).

if [[ -n "$stack_file" ]]; then
  [[ -f "$stack_file" ]] || nyann::die "--stack file not found: $stack_file"
  stack_json=$(<"$stack_file")
  jq empty <<<"$stack_json" 2>/dev/null \
    || nyann::die "--stack file is not valid JSON: $stack_file"
  nyann::log "using pre-computed stack from $stack_file"
else
  stack_json=$("${_script_dir}/detect-stack.sh" --path "$target") \
    || nyann::die "detect-stack.sh failed"
fi

# Extract all fields in one jq call. IFS=$'\t' so empty middle fields
# (e.g. framework="null" while package_manager is set) don't shift later
# variables under default IFS, which collapses runs of whitespace.
IFS=$'\t' read -r detected_lang detected_fw detected_pm detected_confidence is_monorepo < <(
  jq -r '[
    (.primary_language // "unknown"),
    (.framework // "null"),
    (.package_manager // "null"),
    (.confidence // 0),
    (.is_monorepo // false)
  ] | @tsv' <<<"$stack_json"
)
secondary_langs_json=$(jq -c '.secondary_languages // []' <<<"$stack_json")

nyann::log "detected: lang=$detected_lang fw=$detected_fw pm=$detected_pm confidence=$detected_confidence"

secondary_count=$(jq 'length' <<<"$secondary_langs_json")
if (( secondary_count > 0 )); then
  nyann::log "secondary languages: $(jq -r 'join(", ")' <<<"$secondary_langs_json")"
fi

# --- scoring function -------------------------------------------------------
# score_profiles <match_lang> <match_fw> <match_pm>
# Collects all profile files, then scores them in a single jq invocation
# instead of spawning multiple jq subprocesses per profile.

score_profiles() {
  local match_lang="$1" match_fw="$2" match_pm="$3"
  local profiles_dir="$plugin_root/profiles"

  # Collect profile paths into an array. User profiles take precedence
  # over starter profiles of the same name (mirrors load-profile.sh
  # resolution order) so user customisations are not lost to a tied
  # confidence score with the starter. Bash 3.2 compatible — pipe-delimited
  # string instead of associative array.
  local -a profile_files=()
  local seen_names="|"
  local _name
  if [[ -d "$user_root/profiles" ]]; then
    for f in "$user_root/profiles"/*.json; do
      [[ -f "$f" ]] || continue
      _name="$(basename "$f" .json)"
      [[ "$_name" == "_schema" ]] && continue
      profile_files+=("$f")
      seen_names="${seen_names}${_name}|"
    done
  fi
  for f in "$profiles_dir"/*.json; do
    [[ -f "$f" ]] || continue
    _name="$(basename "$f" .json)"
    [[ "$_name" == "_schema" ]] && continue
    [[ "$seen_names" == *"|${_name}|"* ]] && continue
    profile_files+=("$f")
  done

  # Pre-filter malformed JSON. A single bad file in ~/.claude/nyann/profiles/
  # would otherwise abort the entire batch (jq -n inputs exits 5 on the first
  # parse error), making bootstrap step 2 fail for every repo on the machine.
  local -a valid_files=()
  for f in "${profile_files[@]}"; do
    if jq empty "$f" >/dev/null 2>&1; then
      valid_files+=("$f")
    else
      nyann::warn "skipping malformed profile: $f"
    fi
  done
  profile_files=("${valid_files[@]}")

  (( ${#profile_files[@]} == 0 )) && { echo '[]'; return; }

  # Feed all profiles as a JSON stream to a single jq invocation that
  # scores, filters, deduplicates, and sorts in one pass.
  jq -n \
    --arg ml "$match_lang" --arg mf "$match_fw" --arg mp "$match_pm" \
    '[inputs |
      (.stack.primary_language // "unknown") as $pl |
      (.stack.framework // "null") as $pf |
      (.stack.package_manager // "null") as $pm |
      (input_filename | split("/") | last | rtrimstr(".json")) as $name |

      # Score computation
      0 as $s |

      # Language match (strongest signal)
      (if $pl == $ml and $pl != "unknown" then
         { s: ($s + 50), r: ["language match: " + $ml] }
       elif $pl == "unknown" and $ml == "unknown" then
         { s: ($s + 20), r: ["both unknown language"] }
       # JS/TS affinity
       elif ($ml == "javascript" and $pl == "typescript") or
            ($ml == "typescript" and $pl == "javascript") then
         { s: ($s + 35), r: ["JS/TS affinity: " + $ml + " ≈ " + $pl] }
       else
         { s: $s, r: [] }
       end) as $lang_result |

      # Framework match
      ($lang_result |
       if $pf != "null" and $mf != "null" and $pf == $mf then
         { s: (.s + 40), r: (.r + ["framework match: " + $mf]) }
       elif $pf == "null" and $mf == "null" and .s > 0 then
         { s: (.s + 5), r: (.r + ["no framework (matches generic profile)"]) }
       else . end) as $fw_result |

      # Package manager match (weak signal)
      ($fw_result |
       if $pm != "null" and $mp != "null" and $pm == $mp then
         { s: (.s + 5), r: (.r + ["package manager match: " + $mp]) }
       else . end) as $final |

      select($final.s > 0) |
      { name: $name,
        confidence: ([$final.s, 100] | min),
        reasons: $final.r }
    ] |
    group_by(.name) |
    map(sort_by(-.confidence) | .[0]) |
    sort_by(-.confidence)' "${profile_files[@]}"
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

# --- workspace suggestions (monorepos only) ---------------------------------
# For each workspace in the StackDescriptor, score profiles independently
# using the workspace's own language/framework/package_manager. This gives
# the bootstrap flow per-workspace profile recommendations.

workspace_suggestions='[]'
if [[ "$is_monorepo" == "true" ]]; then
  workspaces_json=$(jq -c '.workspaces // []' <<<"$stack_json")
  ws_count=$(jq 'length' <<<"$workspaces_json")
  if (( ws_count > 0 )); then
    while IFS=$'\t' read -r ws_path ws_lang ws_fw ws_pm; do
      [[ -z "$ws_path" || "$ws_lang" == "unknown" ]] && continue
      ws_matches=$(score_profiles "$ws_lang" "$ws_fw" "$ws_pm")
      top_name=$(jq -r '.[0].name // empty' <<<"$ws_matches")
      top_confidence=$(jq '.[0].confidence // 0' <<<"$ws_matches")
      top_reasons=$(jq -c '.[0].reasons // []' <<<"$ws_matches")
      workspace_suggestions=$(jq \
        --arg path "$ws_path" \
        --arg lang "$ws_lang" \
        --arg fw "$ws_fw" \
        --arg suggestion "${top_name:-null}" \
        --argjson confidence "${top_confidence:-0}" \
        --argjson reasons "${top_reasons:-[]}" \
        '. + [{
          path: $path,
          language: $lang,
          framework: (if $fw == "null" then null else $fw end),
          suggestion: (if $suggestion == "null" then null else $suggestion end),
          confidence: $confidence,
          reasons: $reasons
        }]' <<<"$workspace_suggestions")
    done < <(jq -r '.[] | [.path, (.primary_language // "unknown"), (.framework // "null"), (.package_manager // "null")] | @tsv' <<<"$workspaces_json")
  fi
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
  --argjson workspace_suggestions "$workspace_suggestions" \
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
    secondary_suggestions: $secondary_suggestions,
    workspace_suggestions: $workspace_suggestions
  }'
