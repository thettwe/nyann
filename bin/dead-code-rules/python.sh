#!/usr/bin/env bash
# Python rule (portable bash, no gawk).
file="$1"
[[ -f "$file" ]] || exit 0

emit() {
  local lineno="$1" name="$2"
  # `-e` defeats grep-flag injection if the identifier ever starts with
  # `-`. ERE metacharacters can't appear because the upstream regex
  # restricts $name to `[A-Za-z_][A-Za-z0-9_]*`.
  local total
  total=$(grep -nE -e "\\b${name}\\b" "$file" 2>/dev/null \
    | awk -F: -v ln="$lineno" '$1 != ln {n++} END {print n+0}')
  if [[ "$total" -eq 0 ]]; then
    printf '{"file":"%s","line":%d,"kind":"unused-import","name":"%s","confidence":"high","rule":"python"}\n' \
      "$file" "$lineno" "$name"
  fi
}

lineno=0
in_doc=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  # Toggle docstring state on lines that contain `"""`.
  if [[ "$line" == *'"""'* ]]; then
    # Count occurrences to handle a single-line "..." docstring.
    n=$(printf '%s\n' "$line" | tr -cd '"' | awk '{print length($0)/3}')
    n=${n%.*}
    in_doc=$(( (in_doc + n) % 2 ))
  fi
  (( in_doc )) && continue

  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    import\ *|from\ *) ;;
    *) continue ;;
  esac

  # `import X` or `import X as Y` (single name; comma form is rare in
  # modern style and intentionally not supported here).
  if [[ "$trimmed" =~ ^import[[:space:]]+([A-Za-z_][A-Za-z0-9_.]*)([[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*))?[[:space:]]*$ ]]; then
    local_name="${BASH_REMATCH[3]}"
    [[ -z "$local_name" ]] && local_name="${BASH_REMATCH[1]}"
    # `import a.b.c` → top-level identifier is `a`.
    if [[ "$local_name" == *.* ]]; then
      local_name="${local_name%%.*}"
    fi
    emit "$lineno" "$local_name"
    continue
  fi

  # `from M import A, B as C, D` (handle wrapped-paren form too).
  if [[ "$trimmed" =~ ^from[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[[:space:]]+import[[:space:]]+(.+)$ ]]; then
    body="${BASH_REMATCH[1]}"
    body="${body//(/}"
    body="${body//)/}"
    IFS=','
    for raw in $body; do
      part="${raw#"${raw%%[![:space:]]*}"}"
      part="${part%"${part##*[![:space:]]}"}"
      [[ -z "$part" || "$part" == "*" ]] && continue
      if [[ "$part" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+as[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        emit "$lineno" "${BASH_REMATCH[1]}"
      elif [[ "$part" =~ ^([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        emit "$lineno" "${BASH_REMATCH[1]}"
      fi
    done
    unset IFS
    continue
  fi
done < "$file"
