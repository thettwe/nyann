#!/usr/bin/env bash
# Detector: unpinned IaC refs (severity high). Surfaces dependencies pinned
# to a moving target instead of an immutable tag/SHA:
#
#   - Terraform module `source = "...?ref=main|master|HEAD|latest"` (or a
#     branch name) instead of `?ref=<semver-tag>` / `?ref=<40-hex-sha>`.
#   - Terraform `provider`/`required_providers` without a `version =`
#     constraint.
#   - Helm `dependencies:` entries without a pinned `version:` (or with a
#     range like `^`/`~`/`>=`/`*`).
#   - CDK/Pulumi deps in package.json / requirements.txt pinned to
#     `*` / `latest` (npm) or unpinned (no `==` in requirements.txt).
#
# Tag-pinned (`?ref=v1.2.0`) or SHA-pinned (`?ref=<40hex>`) = clean.
#
# Usage: unpinned-refs.sh --target <dir> --file <relpath>
# Emits NDJSON Finding objects on stdout. Exits 0 on any guard failure.

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

base="$(basename "$file")"

emit() {
  # emit <kind-ignored> <line> <message> <current> <expected> <hint>
  local line="$1" message="$2" current="$3" expected="$4" hint="$5"
  jq -n --arg kind "unpinned-ref" \
        --arg file "$file" \
        --argjson line "$line" \
        --arg severity "high" \
        --arg message "$message" \
        --arg current "$current" \
        --arg expected "$expected" \
        --arg hint "$hint" \
        '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, expected:$expected, fix_hint:$hint}'
}

# A ref is "pinned" if it's a semver-ish tag (optionally v-prefixed) or a
# 7-40 char hex SHA. Everything else (main, master, HEAD, latest, a branch
# name) is a moving target.
ref_is_pinned() {
  local r="$1"
  [[ "$r" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?([.-][0-9A-Za-z.-]+)?$ ]] && return 0
  [[ "$r" =~ ^[0-9a-fA-F]{7,40}$ ]] && return 0
  return 1
}

# --- Terraform (.tf) ---------------------------------------------------------
if [[ "$file" == *.tf ]]; then
  in_provider_block=0   # inside a `provider "x" {` block
  in_rp_block=0         # inside a `required_providers {` block
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$line" in *'# drift-ignore'*|*'#drift-ignore'*) continue ;; esac

    # Module source with a ?ref= query — flag when the ref is not pinned.
    case "$line" in
      *source*'?ref='*)
        ref="${line#*\?ref=}"
        # Strip closing quote / trailing query params / whitespace.
        ref="${ref%%\"*}"; ref="${ref%%\'*}"; ref="${ref%%&*}"; ref="${ref%% *}"
        if [[ -n "$ref" ]] && ! ref_is_pinned "$ref"; then
          emit "$lineno" \
            "module source pinned to moving ref '?ref=${ref}' instead of a tag/SHA" \
            "?ref=${ref}" "?ref=<tag-or-sha>" \
            "pin to an immutable tag (?ref=v1.2.0) or commit SHA, or wrap the line with '# drift-ignore'"
        fi
        ;;
    esac

    # provider "name" {  → start tracking for a version constraint.
    if [[ "$line" =~ ^[[:space:]]*provider[[:space:]]+\"([A-Za-z0-9_-]+)\"[[:space:]]*\{ ]]; then
      in_provider_block=1
      provider_has_version=0
      provider_start_line="$lineno"
      provider_name="${BASH_REMATCH[1]}"
      continue
    fi
    if (( in_provider_block )); then
      case "$line" in
        *version*=*) provider_has_version=1 ;;
      esac
      case "$line" in
        *'}'*)
          if (( ! provider_has_version )); then
            emit "$provider_start_line" \
              "provider '${provider_name}' block has no version constraint" \
              "provider \"${provider_name}\" (no version)" "version = \"~> X.Y\"" \
              "add a 'version =' constraint to the provider block (or use required_providers)"
          fi
          in_provider_block=0
          ;;
      esac
      continue
    fi

    # required_providers { name = { source=..., version=... } } — flag any
    # provider entry that has a source but no version.
    if [[ "$line" =~ ^[[:space:]]*required_providers[[:space:]]*\{ ]]; then
      in_rp_block=1
      continue
    fi
    if (( in_rp_block )); then
      case "$line" in
        *'}'*) in_rp_block=0 ;;
      esac
      # Inline single-line entry: name = { source = "x", version = "y" }
      if [[ "$line" == *source*=* && "$line" != *version*=* ]]; then
        entry="${line%%=*}"; entry="${entry//[[:space:]]/}"
        [[ -n "$entry" ]] || entry="provider"
        emit "$lineno" \
          "required_providers entry '${entry}' has a source but no version" \
          "${entry} (no version)" "version = \"~> X.Y\"" \
          "add a 'version =' constraint to the required_providers entry"
      fi
      continue
    fi
  done < "$abs"
fi

# --- Helm Chart.yaml ---------------------------------------------------------
if [[ "$base" == "Chart.yaml" ]]; then
  in_deps=0
  lineno=0
  cur_dep=""
  cur_dep_line=0
  cur_dep_version=""
  flush_dep() {
    [[ -z "$cur_dep" ]] && return 0
    local v="$cur_dep_version"
    # No version, or a moving range (^ ~ >= <= > < * x), is unpinned.
    if [[ -z "$v" ]]; then
      emit "$cur_dep_line" \
        "Helm dependency '${cur_dep}' has no pinned version" \
        "${cur_dep} (no version)" "version: X.Y.Z" \
        "pin the dependency to an exact version (version: 1.2.3), or wrap with '# drift-ignore'"
    elif [[ "$v" == *'^'* || "$v" == *'~'* || "$v" == *'>'* || "$v" == *'<'* || "$v" == *'*'* || "$v" == *' x'* || "$v" == 'x'* ]]; then
      emit "$cur_dep_line" \
        "Helm dependency '${cur_dep}' uses a moving version range '${v}'" \
        "${v}" "X.Y.Z (exact)" \
        "pin the dependency to an exact version instead of a range"
    fi
    cur_dep=""; cur_dep_version=""; cur_dep_line=0
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$line" in *'# drift-ignore'*) continue ;; esac
    case "$line" in
      'dependencies:'*) in_deps=1; continue ;;
    esac
    if (( in_deps )); then
      # A new top-level key (no leading space, ends a logical section) closes
      # the dependencies list.
      if [[ "$line" =~ ^[A-Za-z] ]]; then
        flush_dep
        in_deps=0
        continue
      fi
      # New list item: `  - name: foo`
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
        flush_dep
        cur_dep_line="$lineno"
        if [[ "$line" =~ name:[[:space:]]*([^[:space:]]+) ]]; then
          cur_dep="${BASH_REMATCH[1]}"
        else
          cur_dep="dependency"
        fi
        if [[ "$line" =~ version:[[:space:]]*([^[:space:]]+) ]]; then
          cur_dep_version="${BASH_REMATCH[1]}"
        fi
        continue
      fi
      # Continuation lines of the current dep: `    name: foo` / `    version: x`
      if [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*([^[:space:]]+) ]]; then
        cur_dep="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ ^[[:space:]]+version:[[:space:]]*([^[:space:]]+) ]]; then
        cur_dep_version="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$abs"
  flush_dep
fi

# --- CDK / Pulumi package.json -----------------------------------------------
if [[ "$base" == "package.json" ]]; then
  # Only inspect repos that look like CDK/Pulumi to avoid flagging every JS
  # project. Cheap heuristic: an aws-cdk / @pulumi dependency present.
  if grep -qE '"(aws-cdk-lib|aws-cdk|@pulumi/[a-z-]+|@aws-cdk/)' "$abs" 2>/dev/null; then
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      case "$line" in *'drift-ignore'*) continue ;; esac
      # Match `"pkg": "*"` or `"pkg": "latest"`.
      if [[ "$line" =~ \"([@A-Za-z0-9_./-]+)\"[[:space:]]*:[[:space:]]*\"(\*|latest)\" ]]; then
        pkg="${BASH_REMATCH[1]}"
        ver="${BASH_REMATCH[2]}"
        emit "$lineno" \
          "dependency '${pkg}' pinned to '${ver}' (moving target)" \
          "${pkg}: ${ver}" "${pkg}: X.Y.Z (exact)" \
          "pin '${pkg}' to an exact version instead of '${ver}'"
      fi
    done < "$abs"
  fi
fi

# --- Pulumi requirements.txt (python) ----------------------------------------
if [[ "$base" == "requirements.txt" ]]; then
  # Only inspect when it looks like a Pulumi project (pulumi listed).
  if grep -qiE '^pulumi([-_]|=|>|<|\[|$)' "$abs" 2>/dev/null; then
    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      # Strip comments / whitespace.
      l="${line%%#*}"; l="${l//[[:space:]]/}"
      [[ -z "$l" ]] && continue
      case "$line" in *'drift-ignore'*) continue ;; esac
      # Flag a pulumi* requirement with no `==` exact pin.
      if [[ "$l" =~ ^pulumi ]] && [[ "$l" != *'=='* ]]; then
        emit "$lineno" \
          "Pulumi dependency '${l}' is not pinned to an exact version" \
          "${l}" "pulumi==X.Y.Z" \
          "pin the Pulumi dependency with '==' (e.g. pulumi==3.100.0)"
      fi
    done < "$abs"
  fi
fi

exit 0
