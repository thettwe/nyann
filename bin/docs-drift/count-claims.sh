#!/usr/bin/env bash
# Detector: count-claim drift. Surfaces "<N> <keyword>" claims in the
# README whose actual count diverges from N. Opt-in via profile's
# documentation.drift_check.count_claims.tracked_counts[].
#
# Each tracked count is shaped:
#   { keyword: "tests", source: "filesystem-glob", glob: "tests/bats/*.bats" }
#   { keyword: "tests", source: "filesystem-glob", glob: "tests/**/*.bats", extract: "lines-matching:^@test" }
#
# This script is invoked once per file by the orchestrator; the profile
# is passed via env so we don't have to re-pass the whole CLI.

target=""; file=""; profile_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --file)      file="${2-}"; shift 2 ;;
    --file=*)    file="${1#--file=}"; shift ;;
    --profile)   profile_file="${2-}"; shift 2 ;;
    --profile=*) profile_file="${1#--profile=}"; shift ;;
    *) shift ;;
  esac
done

[[ -n "$target" && -n "$file" ]] || exit 0
[[ -n "$profile_file" && -f "$profile_file" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

abs="$target/$file"
[[ -f "$abs" ]] || exit 0

# Pull tracked_counts; if empty/disabled, exit silently.
enabled=$(jq -r '.documentation.drift_check.count_claims.enabled // false' "$profile_file" 2>/dev/null)
[[ "$enabled" == "true" ]] || exit 0

count_actual() {
  # source = filesystem-glob, glob = "<pattern>", extract = "lines-matching:<regex>" | "files" (default).
  local src="$1" glob="$2" extract="$3"
  case "$src" in
    filesystem-glob)
      # shellcheck disable=SC2086
      if [[ "$extract" == lines-matching:* ]]; then
        local regex="${extract#lines-matching:}"
        ( cd "$target" && find $glob -type f 2>/dev/null | xargs grep -hE "$regex" 2>/dev/null | grep -c '.' ) || echo 0
      else
        ( cd "$target" && find $glob -type f 2>/dev/null | grep -c '.' ) || echo 0
      fi
      ;;
    *) echo 0 ;;
  esac
}

n_tracked=$(jq '.documentation.drift_check.count_claims.tracked_counts // [] | length' "$profile_file")
i=0
while (( i < n_tracked )); do
  keyword=$( jq -r ".documentation.drift_check.count_claims.tracked_counts[$i].keyword" "$profile_file")
  src=$(     jq -r ".documentation.drift_check.count_claims.tracked_counts[$i].source"  "$profile_file")
  glob=$(    jq -r ".documentation.drift_check.count_claims.tracked_counts[$i].glob // empty" "$profile_file")
  extract=$( jq -r ".documentation.drift_check.count_claims.tracked_counts[$i].extract // empty" "$profile_file")
  i=$((i + 1))
  [[ -n "$keyword" && -n "$src" && -n "$glob" ]] || continue

  actual=$(count_actual "$src" "$glob" "$extract")
  actual=${actual//[^0-9]/}
  actual=${actual:-0}

  # Find claim lines: `<digit>+ <keyword>` (allowing comma in the digits).
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$line" in
      *'<!-- drift-ignore -->'*) continue ;;
    esac
    # Look for the keyword preceded by a number (comma-separated allowed).
    while read -r m; do
      [[ -z "$m" ]] && continue
      digits="${m%% *}"
      digits="${digits//,/}"
      [[ "$digits" =~ ^[0-9]+$ ]] || continue
      claim=$digits
      # Compute % diff.
      if (( actual == 0 )); then
        diff_pct=100
      else
        diff_abs=$(( claim - actual ))
        (( diff_abs < 0 )) && diff_abs=$(( -diff_abs ))
        diff_pct=$(( diff_abs * 100 / actual ))
      fi
      if (( claim == actual )); then
        continue
      fi
      if (( diff_pct > 10 )); then
        sev="medium"
      else
        sev="low"
      fi
      jq -n --arg kind "count-claim" \
            --arg file "$file" \
            --argjson line "$lineno" \
            --arg severity "$sev" \
            --arg message "claim '$claim $keyword' diverges from actual count $actual" \
            --arg current "$claim $keyword" \
            --arg expected "$actual $keyword" \
            --arg hint "update the count or wrap with <!-- drift-ignore -->" \
            '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, expected:$expected, fix_hint:$hint}'
    done < <( printf '%s' "$line" | grep -oE "[0-9][0-9,]* +${keyword}\b" )
  done < "$abs"
done
