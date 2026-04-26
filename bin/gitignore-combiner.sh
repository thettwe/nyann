#!/usr/bin/env bash
# gitignore-combiner.sh — merge nyann gitignore templates into a target file.
#
# Usage: gitignore-combiner.sh --target <path> --templates <t1>[,<t2>,...]
#
# Reads the named templates from templates/gitignore/ (relative to this script)
# and appends to --target any entries that are not already present. Comments
# and blank lines from templates are copied verbatim once per template.
#
# Idempotent: re-running on the same target is a no-op after the first pass.
# Deduplicates across templates too, so a .DS_Store entry in both jsts and
# python templates appears once in the output.
#
# Portability note: uses a temp file as the "seen set" instead of associative
# arrays so macOS default bash 3.2 works.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

target=""
templates_csv=""
template_root="${_script_dir}/../templates/gitignore"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --templates)       templates_csv="${2:-}"; shift 2 ;;
    --templates=*)     templates_csv="${1#--templates=}"; shift ;;
    --template-root)   template_root="${2:-}"; shift 2 ;;
    --template-root=*) template_root="${1#--template-root=}"; shift ;;
    -h|--help)
      sed -n '3,17p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" ]] || nyann::die "--target is required"
[[ -n "$templates_csv" ]] || nyann::die "--templates is required"
[[ -d "$template_root" ]] || nyann::die "template root not found: $template_root"

# Refuse a symlinked --target. Without this, a hostile repo with
# `.gitignore` symlinked to `/home/user/.bashrc` would have our
# seed-read + append operations write through to that target. Test
# `-L` before `-f` because `-f` follows symlinks on macOS bash 3.2.
if [[ -L "$target" ]]; then
  nyann::die "refusing to combine gitignore into a symlink: $target"
fi

# --- seen-set: temp file with one normalized pattern per line -----------------

seen_file="$(mktemp -t nyann-gitignore.XXXXXX)"
staged=""
trap 'rm -f "$seen_file" "$staged"' EXIT

# Normalize: strip leading whitespace, skip blanks and full-line comments.
# A pattern line is kept as-is for matching. We purposely don't collapse
# trailing whitespace since some users rely on it.
normalize() {
  local line="$1"
  line="${line%$'\r'}"
  local trimmed="${line#"${line%%[![:space:]]*}"}"
  if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
    return 1
  fi
  printf '%s\n' "$trimmed"
}

# Seed the seen set from the target (if it exists).
if [[ -f "$target" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    if norm=$(normalize "$line"); then
      printf '%s\n' "$norm" >> "$seen_file"
    fi
  done < "$target"
fi

# Ensure target exists and ends with a newline. Command substitution would
# strip a trailing \n, so compare the last byte's octal representation with
# od instead.
if [[ ! -f "$target" ]]; then
  : > "$target"
elif [[ -s "$target" ]]; then
  last_byte_oct="$(tail -c 1 "$target" | od -An -b | tr -d ' ')"
  if [[ "$last_byte_oct" != "012" ]]; then
    printf '\n' >> "$target"
  fi
fi

has_seen() {
  grep -Fxq -- "$1" "$seen_file"
}

IFS=',' read -ra templates <<<"$templates_csv"

any_appended=false

for name in "${templates[@]}"; do
  name="${name// /}"
  [[ -z "$name" ]] && continue
  local_file="${template_root}/${name}.gitignore"
  [[ -f "$local_file" ]] || nyann::die "template not found: $local_file"

  # First pass: stage this template's lines that contribute something new.
  staged="$(mktemp -t nyann-stage.XXXXXX)"
  had_new=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
      printf '%s\n' "$line" >> "$staged"
      continue
    fi
    if has_seen "$trimmed"; then
      continue
    fi
    printf '%s\n' "$trimmed" >> "$seen_file"
    printf '%s\n' "$line" >> "$staged"
    had_new=true
  done < "$local_file"

  if $had_new; then
    {
      printf '\n# --- nyann: %s ---\n' "$name"
      cat "$staged"
    } >> "$target"
    any_appended=true
  fi
  rm -f "$staged"
done

if $any_appended; then
  nyann::log "gitignore updated: $target"
else
  nyann::log "gitignore already current: $target"
fi
