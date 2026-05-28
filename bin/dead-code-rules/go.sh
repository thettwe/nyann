#!/usr/bin/env bash
# Go rule (portable bash). Surfaces unused imports earlier than the compiler.
file="$1"
[[ -f "$file" ]] || exit 0

emit() {
  local lineno="$1" name="$2"
  # `-e` defeats grep-flag injection. Go usage convention: <ident>.<Member>;
  # the trailing `\\.` is the literal dot. Identifier comes from a parser
  # that already restricts to `[A-Za-z_][A-Za-z0-9_]*`.
  local total
  total=$(grep -nE -e "\\b${name}\\." "$file" 2>/dev/null \
    | awk -F: -v ln="$lineno" '$1 != ln {n++} END {print n+0}')
  if [[ "$total" -eq 0 ]]; then
    jq -nc \
      --arg file "$file" \
      --argjson line "$lineno" \
      --arg name "$name" \
      '{file:$file, line:$line, kind:"unused-import", name:$name, confidence:"high", rule:"go"}'
  fi
}

lineno=0
in_block=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  if [[ "$line" =~ ^[[:space:]]*import[[:space:]]+\( ]]; then
    in_block=1
    continue
  fi
  if (( in_block )); then
    if [[ "$line" =~ ^[[:space:]]*\) ]]; then
      in_block=0
      continue
    fi
    # Inside block: lines look like `    "fmt"` or `    alias "path/pkg"`.
    if [[ "$line" =~ ^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*|_|\.)[[:space:]]+)?\"([^\"]+)\" ]]; then
      alias="${BASH_REMATCH[2]}"
      path="${BASH_REMATCH[3]}"
      [[ "$alias" == "_" || "$alias" == "." ]] && continue
      if [[ -z "$alias" ]]; then
        # Last segment of path is the package name.
        alias="${path##*/}"
      fi
      emit "$lineno" "$alias"
    fi
    continue
  fi

  # Single-line import: `import "fmt"` or `import alias "fmt"`.
  if [[ "$line" =~ ^[[:space:]]*import[[:space:]]+(([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+)?\"([^\"]+)\" ]]; then
    alias="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[3]}"
    if [[ -z "$alias" ]]; then
      alias="${path##*/}"
    fi
    emit "$lineno" "$alias"
  fi
done < "$file"
