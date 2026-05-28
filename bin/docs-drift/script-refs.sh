#!/usr/bin/env bash
# Detector: script-ref drift. Surfaces `npm run X` / `pnpm X` / `yarn X` /
# `make X` invocations in markdown that no longer exist in the relevant
# manifest.

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

# Pre-load script lists from manifests if present.
npm_scripts=""
if [[ -f "$target/package.json" ]] && command -v jq >/dev/null 2>&1; then
  npm_scripts=$(jq -r '.scripts // {} | keys[]' "$target/package.json" 2>/dev/null || true)
fi

make_targets=""
if [[ -f "$target/Makefile" ]]; then
  # Lines like `target:` (with optional spaces / dependencies).
  make_targets=$(grep -E '^[a-zA-Z_][a-zA-Z0-9_.-]*:' "$target/Makefile" 2>/dev/null | sed 's/:.*//' | sort -u || true)
fi

# Helper: does a script exist?
has_npm_script() {
  [[ -z "$npm_scripts" ]] && return 1
  printf '%s\n' "$npm_scripts" | grep -Fqx "$1"
}
has_make_target() {
  [[ -z "$make_targets" ]] && return 1
  printf '%s\n' "$make_targets" | grep -Fqx "$1"
}

# Walk every line of the doc — script invocations appear both in fenced
# code blocks and in prose ("run `npm run build` to compile"). Track
# fence state only so we can skip the fence delimiters themselves.
in_fence=0
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  case "$line" in
    '```'*|'~~~'*)
      in_fence=$((1 - in_fence))
      continue
      ;;
    *'<!-- drift-ignore -->'*) continue ;;
  esac

  # `npm run X` / `npm X` (with X being a script word).
  while read -r m; do
    [[ -z "$m" ]] && continue
    s="${m#npm run }"; s="${s%% *}"
    [[ -n "$s" ]] || continue
    if [[ -n "$npm_scripts" ]] && ! has_npm_script "$s"; then
      jq -n --arg kind "script-ref" \
            --arg file "$file" \
            --argjson line "$lineno" \
            --arg severity "high" \
            --arg message "npm script '$s' referenced but not in package.json" \
            --arg current "npm run $s" \
            --arg hint "remove the reference or add '$s' to package.json scripts" \
            '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, fix_hint:$hint}'
    fi
  done < <( printf '%s' "$line" | grep -oE 'npm run [a-zA-Z0-9:_-]+' )

  while read -r m; do
    [[ -z "$m" ]] && continue
    s="${m#make }"; s="${s%% *}"
    [[ -n "$s" ]] || continue
    if [[ -n "$make_targets" ]] && ! has_make_target "$s"; then
      jq -n --arg kind "script-ref" \
            --arg file "$file" \
            --argjson line "$lineno" \
            --arg severity "high" \
            --arg message "make target '$s' referenced but not in Makefile" \
            --arg current "make $s" \
            --arg hint "remove the reference or add '$s' to Makefile" \
            '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, fix_hint:$hint}'
    fi
  done < <( printf '%s' "$line" | grep -oE 'make [a-zA-Z0-9:_./-]+' )
done < "$abs"
