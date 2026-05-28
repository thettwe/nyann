#!/usr/bin/env bash
# Detector: file-ref drift. Surfaces relative file/path references in markdown
# that don't exist on the filesystem.
#
# Scans:
#   - `[text](path)` links where path is repo-relative
#   - inline backticks containing path-like tokens (skipped — too noisy)
#
# Skips: absolute paths (/etc/...), URLs (http(s)://...), anchors (#...),
# tilde paths (~/...), lines marked <!-- drift-ignore -->.

target=""; file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --file)     file="${2-}"; shift 2 ;;
    --file=*)   file="${1#--file=}"; shift ;;
    *) shift ;;
  esac
done

[[ -n "$target" && -n "$file" ]] || exit 0
abs="$target/$file"
[[ -f "$abs" ]] || exit 0

file_dir=$(dirname "$file")
[[ "$file_dir" == "." ]] && file_dir=""

# Track fenced-code-block state so we don't flag illustrative path examples
# inside ``` blocks (a common false-positive source — README tutorials
# routinely show `[file](src/example.ts)` as a syntax demo, not a real ref).
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
    *'<!--'*'-->'*) continue ;;
  esac
  # Extract [text](path) targets. POSIX-portable grep -oE.
  # The pattern matches `(...path...)` capturing the path. We use grep -oP
  # if available (GNU) else fall back to grep -oE and post-process.
  while read -r raw; do
    [[ -z "$raw" ]] && continue
    # raw looks like `(path)` — strip parens.
    path="${raw#(}"
    path="${path%)}"
    # Strip optional title `path "title"`.
    path="${path%% *}"
    # Strip query/fragment.
    path="${path%%#*}"
    path="${path%%\?*}"
    # Skip URLs / absolute / home / anchors / mailto.
    case "$path" in
      ""|"#"*|"/"*|"~"*) continue ;;
      http://*|https://*|mailto:*|ftp://*|tel:*) continue ;;
    esac
    # Resolve relative to file_dir.
    if [[ -n "$file_dir" && "$path" != /* ]]; then
      candidate="$target/$file_dir/$path"
    else
      candidate="$target/$path"
    fi
    if [[ ! -e "$candidate" ]]; then
      msg="missing reference: ${path}"
      jq -n --arg kind "file-ref" \
            --arg file "$file" \
            --argjson line "$lineno" \
            --arg severity "high" \
            --arg message "$msg" \
            --arg current "$path" \
            --arg hint "either create ${path}, fix the link, or wrap the line with <!-- drift-ignore -->" \
            '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, fix_hint:$hint}'
    fi
  done < <( printf '%s' "$line" | grep -oE '\([^)[:space:]]+\.[A-Za-z0-9_/-]+\)' )
done < "$abs"
