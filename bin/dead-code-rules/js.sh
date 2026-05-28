#!/usr/bin/env bash
# JS/TS rule: flag ES-module imports whose names don't appear elsewhere
# in the file. Portable shell — uses POSIX sed + grep, not gawk extensions.
#
# Conservative heuristic. Side-effect imports (`import "x";`) are skipped.

file="$1"
[[ -f "$file" ]] || exit 0

emit() {
  local lineno="$1" name="$2"
  # Count refs to name outside the declaring line.
  local total
  total=$(grep -nE "\\b${name}\\b" "$file" 2>/dev/null \
    | awk -F: -v ln="$lineno" '$1 != ln {n++} END {print n+0}')
  if [[ "$total" -eq 0 ]]; then
    printf '{"file":"%s","line":%d,"kind":"unused-import","name":"%s","confidence":"high","rule":"js"}\n' \
      "$file" "$lineno" "$name"
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
  # Named imports: `import { A, B as C } from "x"`
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
