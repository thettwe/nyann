#!/usr/bin/env bash
# Rust rule (portable bash). Skips `as _` and `self`.
file="$1"
[[ -f "$file" ]] || exit 0

emit() {
  local lineno="$1" name="$2"
  # `-e` defeats grep-flag injection. Identifier comes from a parser
  # that already restricts to `[A-Za-z_][A-Za-z0-9_]*`.
  local total
  total=$(grep -nE -e "\\b${name}\\b" "$file" 2>/dev/null \
    | awk -F: -v ln="$lineno" '$1 != ln {n++} END {print n+0}')
  if [[ "$total" -eq 0 ]]; then
    jq -nc \
      --arg file "$file" \
      --argjson line "$lineno" \
      --arg name "$name" \
      '{file:$file, line:$line, kind:"unused-import", name:$name, confidence:"high", rule:"rust"}'
  fi
}

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  # `use a::b::Foo;` or `use a::b::Foo as Bar;`
  if [[ "$line" =~ ^[[:space:]]*(pub[[:space:]]+)?use[[:space:]]+[A-Za-z0-9_:]+::([A-Za-z_][A-Za-z0-9_]*)([[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*))?\; ]]; then
    # `pub use` is a re-export = public API surface, not dead code.
    [[ -n "${BASH_REMATCH[1]}" ]] && continue
    last="${BASH_REMATCH[2]}"
    alias="${BASH_REMATCH[4]}"
    local_name="${alias:-$last}"
    [[ "$local_name" == "_" ]] && continue
    emit "$lineno" "$local_name"
    continue
  fi
  # `use a::b::{Foo, Bar as Baz};`
  if [[ "$line" =~ ^[[:space:]]*(pub[[:space:]]+)?use[[:space:]]+[A-Za-z0-9_:]+::\{([^}]+)\}\; ]]; then
    # `pub use` is a re-export = public API surface, not dead code.
    [[ -n "${BASH_REMATCH[1]}" ]] && continue
    body="${BASH_REMATCH[2]}"
    IFS=','
    for raw in $body; do
      part="${raw#"${raw%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -z "$part" || "$part" == "self" ]] && continue
      if [[ "$part" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        [[ "${BASH_REMATCH[2]}" == "_" ]] && continue
        emit "$lineno" "${BASH_REMATCH[2]}"
      elif [[ "$part" =~ ^([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        emit "$lineno" "${BASH_REMATCH[1]}"
      fi
    done
    unset IFS
    continue
  fi
done < "$file"
