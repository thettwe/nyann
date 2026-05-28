#!/usr/bin/env bash
# JS/TS rule: flag ES-module imports whose names don't appear elsewhere
# in the file. Portable shell — uses POSIX sed + grep, not gawk extensions.
#
# Conservative heuristic. Side-effect imports (`import "x";`) are skipped.

file="$1"
[[ -f "$file" ]] || exit 0

emit() {
  local lineno="$1" name="$2"
  # The upstream regex restricts $name to `[A-Za-z_$][A-Za-z0-9_$]*`, so
  # ERE metacharacters can't appear here. We do still pass the pattern
  # via `-e` so a hypothetical identifier starting with `-` (or a future
  # parser relaxation) can't be misread as a grep flag.
  local total
  total=$(grep -nE -e "\\b${name}\\b" "$file" 2>/dev/null \
    | awk -F: -v ln="$lineno" '$1 != ln {n++} END {print n+0}')
  if [[ "$total" -eq 0 ]]; then
    # Use jq -n --arg / --argjson so filenames containing `"` or `\\`
    # produce well-formed JSON. Raw printf would break downstream
    # `jq -s` aggregation on such paths.
    jq -nc \
      --arg file "$file" \
      --argjson line "$lineno" \
      --arg name "$name" \
      '{file:$file, line:$line, kind:"unused-import", name:$name, confidence:"high", rule:"js"}'
  fi
}

# Walk the file line by line. We only care about lines starting with `import`.
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    import\ *) ;;
    *) continue ;;
  esac

  # Strip optional TypeScript `type` / `typeof` modifier so the regex
  # captures the actual identifier rather than the keyword. Without this,
  # `import type Foo from "x"` would match Foo... but `type` would be
  # captured as the identifier and Foo's usage would be missed entirely.
  if [[ "$trimmed" =~ ^import[[:space:]]+(type|typeof)[[:space:]]+(.+)$ ]]; then
    trimmed="import ${BASH_REMATCH[2]}"
  fi
  # Default import: `import Foo from "x"` (no braces, no *)
  if [[ "$trimmed" =~ ^import[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)[[:space:]]+from ]]; then
    emit "$lineno" "${BASH_REMATCH[1]}"
    continue
  fi
  # Namespace: `import * as Foo from "x"`
  if [[ "$trimmed" =~ ^import[[:space:]]+\*[[:space:]]+as[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)[[:space:]]+from ]]; then
    emit "$lineno" "${BASH_REMATCH[1]}"
    continue
  fi
  # Named imports: `import { A, B as C } from "x"` (also `import type { ... }`
  # after the modifier strip above).
  if [[ "$trimmed" =~ ^import[[:space:]]+\{([^}]+)\}[[:space:]]+from ]]; then
    body="${BASH_REMATCH[1]}"
    # Split on commas.
    IFS=','
    for raw in $body; do
      # Trim.
      part="${raw#"${raw%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -z "$part" ]] && continue
      # `Foo as Bar` → local name is Bar.
      if [[ "$part" =~ ^[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]+as[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)$ ]]; then
        emit "$lineno" "${BASH_REMATCH[1]}"
      elif [[ "$part" =~ ^([A-Za-z_$][A-Za-z0-9_$]*)$ ]]; then
        emit "$lineno" "${BASH_REMATCH[1]}"
      fi
    done
    unset IFS
    continue
  fi
done < "$file"
