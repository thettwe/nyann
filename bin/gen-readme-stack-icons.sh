#!/usr/bin/env bash
# gen-readme-stack-icons.sh — emit a skillicons.dev block for README.md.
#
# Usage:
#   gen-readme-stack-icons.sh [--target <dir>] [--profile <file>] [--apply]
#                             [--stack <stack-descriptor.json>]
#
# Uses templates/stack-icon-map.json to translate detected stack signals
# (primary_language, framework, package_managers, secondary_languages)
# into skillicons.dev slugs. Profile may override via:
#   documentation.readme_stack_icons.include[]  — extra slugs (appended)
#   documentation.readme_stack_icons.exclude[]  — slugs to remove

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_file=""
stack_file=""
apply=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --profile)   profile_file="${2-}"; shift 2 ;;
    --profile=*) profile_file="${1#--profile=}"; shift ;;
    --stack)     stack_file="${2-}"; shift 2 ;;
    --stack=*)   stack_file="${1#--stack=}"; shift ;;
    --apply)     apply=true; shift ;;
    -h|--help)   sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
cd "$target" || nyann::die "cd $target failed"

# Master switch.
master="true"
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  m=$(jq -r 'if .documentation.readme_stack_icons.enabled == false then "false" elif .documentation.readme_stack_icons.enabled == true then "true" else "" end' "$profile_file" 2>/dev/null)
  [[ -n "$m" ]] && master="$m"
fi

# Detect stack if not provided.
if [[ -z "$stack_file" ]]; then
  stack_file=$(mktemp -t nyann-stack.XXXXXX)
  trap 'rm -f "$stack_file"' EXIT
  if ! bash "${_script_dir}/detect-stack.sh" --path "$target" > "$stack_file" 2>/dev/null; then
    echo '{}' > "$stack_file"
  fi
fi

icon_map="${_script_dir}/../templates/stack-icon-map.json"
[[ -f "$icon_map" ]] || nyann::die "icon map not found: $icon_map"

# Build slug list.
declare -a slugs=()
add_slug_for() {
  local category="$1" key="$2"
  [[ -z "$key" || "$key" == "null" ]] && return
  local arr
  arr=$(jq -r --arg cat "$category" --arg k "$key" '.[$cat][$k] // [] | .[]' "$icon_map" 2>/dev/null || true)
  while IFS= read -r s; do
    [[ -n "$s" ]] && slugs+=("$s")
  done <<< "$arr"
}

primary_lang=$(jq -r '.primary_language // empty' "$stack_file" 2>/dev/null || true)
framework=$(  jq -r '.framework // empty'        "$stack_file" 2>/dev/null || true)
add_slug_for languages "$primary_lang"
add_slug_for frameworks "$framework"

while IFS= read -r l; do
  add_slug_for languages "$l"
done < <( jq -r '.secondary_languages // [] | .[]' "$stack_file" 2>/dev/null )

while IFS= read -r p; do
  add_slug_for infra "$p"
done < <( jq -r '.package_managers // [] | .[]' "$stack_file" 2>/dev/null )

# Profile overrides.
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  while IFS= read -r s; do
    [[ -n "$s" ]] && slugs+=("$s")
  done < <( jq -r '.documentation.readme_stack_icons.include // [] | .[]' "$profile_file" 2>/dev/null )

  declare -a excludes=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && excludes+=("$s")
  done < <( jq -r '.documentation.readme_stack_icons.exclude // [] | .[]' "$profile_file" 2>/dev/null )

  if (( ${#excludes[@]} > 0 )); then
    declare -a filtered=()
    for s in "${slugs[@]}"; do
      keep=1
      for e in "${excludes[@]}"; do
        [[ "$s" == "$e" ]] && { keep=0; break; }
      done
      (( keep )) && filtered+=("$s")
    done
    slugs=("${filtered[@]}")
  fi
fi

# Dedupe while preserving order.
declare -a unique=()
seen=" "
for s in "${slugs[@]:-}"; do
  [[ -z "$s" ]] && continue
  case "$seen" in *" $s "*) continue ;; esac
  unique+=("$s")
  seen+="$s "
done
slugs=("${unique[@]:-}")

# Compose URL.
joined=$(IFS=','; printf '%s' "${slugs[*]:-}")
if [[ -n "$joined" && "$master" == "true" ]]; then
  block_body=$(printf '<a href="https://skillicons.dev">\n  <img src="https://skillicons.dev/icons?i=%s" />\n</a>' "$joined")
else
  block_body=""
fi

marker_start='<!-- nyann:stack-icons:start -->'
marker_end='<!-- nyann:stack-icons:end -->'

rendered="${marker_start}"
if [[ -n "$block_body" ]]; then
  rendered+=$'\n'"${block_body}"
fi
rendered+=$'\n'"${marker_end}"

action="preview"
diff_summary="no change (preview only)"
if $apply; then
  readme="README.md"
  # Follow symlinks — see gen-readme-badges.sh for rationale.
  if [[ -L "$readme" ]]; then
    readme_target=$(readlink "$readme")
    case "$readme_target" in
      /*) readme="$readme_target" ;;
      *)  readme="$(dirname "$readme")/$readme_target" ;;
    esac
  fi
  if [[ ! -f "$readme" ]]; then
    printf '%s\n' "$rendered" > "$readme"
    action="write"
    diff_summary="created README.md with stack-icon block"
  elif grep -Fq "$marker_start" "$readme"; then
    # BSD awk rejects multi-line -v vars; spool body to file and load via getline.
    body_tmp=$(mktemp -t nyann-body.XXXXXX)
    printf '%s' "$rendered" > "$body_tmp"
    tmp=$(mktemp -t nyann-readme.XXXXXX)
    awk -v ms="$marker_start" -v me="$marker_end" -v bf="$body_tmp" '
      BEGIN {
        skip=0
        while ((getline line < bf) > 0) {
          body = body (body == "" ? "" : "\n") line
        }
      }
      index($0, ms) { print body; skip=1; next }
      index($0, me) { skip=0; next }
      !skip { print }
    ' "$readme" > "$tmp"
    # Defensive: orphaned marker_start without marker_end would truncate
    # README silently — refuse rather than commit a destructive write.
    if ! grep -Fq "$marker_end" "$tmp"; then
      rm -f "$tmp" "$body_tmp"
      nyann::die "README.md has an orphaned marker_start without a matching marker_end; refusing to truncate. Repair the file manually then re-run --apply."
    fi
    mv "$tmp" "$readme"
    rm -f "$body_tmp"
    action="write"
    diff_summary="replaced existing stack-icon block"
  else
    tmp=$(mktemp -t nyann-readme.XXXXXX)
    printf '%s\n\n%s' "$rendered" "$(cat "$readme")" > "$tmp"
    mv "$tmp" "$readme"
    action="write"
    diff_summary="inserted stack-icon block at top of README"
  fi
fi

if (( ${#slugs[@]} == 0 )); then
  slugs_json='[]'
else
  slugs_json=$(printf '%s\n' "${slugs[@]}" | jq -R . | jq -s 'map(select(length > 0))')
fi

jq -n \
  --arg target "$target" \
  --arg ms "$marker_start" \
  --arg me "$marker_end" \
  --arg rendered "$rendered" \
  --arg action "$action" \
  --arg diff "$diff_summary" \
  --argjson slugs "$slugs_json" \
  '{target:$target, block_kind:"stack-icons", marker_start:$ms, marker_end:$me, lines:$slugs, rendered:$rendered, action:$action, diff_summary:$diff}'
