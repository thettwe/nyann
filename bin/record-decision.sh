#!/usr/bin/env bash
# record-decision.sh — append a new ADR to docs/decisions with an
# auto-incremented number.
#
# Usage:
#   record-decision.sh --target <repo> --title "<title>"
#                      [--dir <path>]            # default: docs/decisions
#                      [--status proposed|accepted]   # default: proposed
#                      [--date YYYY-MM-DD]       # default: today (UTC)
#                      [--slug <slug>]           # default: derived from title
#                      [--format madr]           # only MADR in v1
#                      [--dry-run]
#
# Behavior:
#   1. Resolve the ADR directory; create it if missing.
#   2. Find the highest existing ADR number (matches ADR-NNN-*.md).
#      Next ADR = N+1, zero-padded to 3 digits.
#   3. Render a MADR template (copy templates/docs/decisions/ADR-template.md),
#      substituting number + title + status + date.
#   4. Write to <dir>/ADR-<nnn>-<slug>.md. Refuse to overwrite.
#
# Output (JSON on stdout):
#   { "path": "docs/decisions/ADR-042-foo.md",
#     "number": 42, "title": "Foo", "status": "proposed",
#     "date": "2026-04-23", "slug": "foo", "dry_run": false }

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
title=""
dir=""
status="proposed"
date_str=""
slug=""
format="madr"
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --title)        title="${2:-}"; shift 2 ;;
    --title=*)      title="${1#--title=}"; shift ;;
    --dir)          dir="${2:-}"; shift 2 ;;
    --dir=*)        dir="${1#--dir=}"; shift ;;
    --status)       status="${2:-}"; shift 2 ;;
    --status=*)     status="${1#--status=}"; shift ;;
    --date)         date_str="${2:-}"; shift 2 ;;
    --date=*)       date_str="${1#--date=}"; shift ;;
    --slug)         slug="${2:-}"; shift 2 ;;
    --slug=*)       slug="${1#--slug=}"; shift ;;
    --format)       format="${2:-}"; shift 2 ;;
    --format=*)     format="${1#--format=}"; shift ;;
    --dry-run)      dry_run=true; shift ;;
    -h|--help)      sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- validate inputs ---------------------------------------------------------

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"

[[ -n "$title" ]] || nyann::die "--title is required"

case "$status" in proposed|accepted) ;; *) nyann::die "--status must be proposed|accepted" ;; esac
case "$format" in madr) ;; *) nyann::die "--format: only 'madr' is supported in v1" ;; esac

[[ -n "$date_str" ]] || date_str=$(date -u +%Y-%m-%d)
if ! [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  nyann::die "--date must be YYYY-MM-DD: got '$date_str'"
fi

[[ -n "$dir" ]] || dir="docs/decisions"
# Reject absolute / traversal --dir values *before* concatenating with
# $target. Otherwise `--dir ../../tmp` silently writes ADRs outside
# the repo.
if [[ "$dir" == /* || "$dir" == *".."* ]]; then
  nyann::die "--dir rejected (absolute or contains '..'): $dir"
fi
abs_dir=$(nyann::assert_path_under_target "$target" "$target/$dir" "--dir '$dir'")

# --- derive slug -------------------------------------------------------------

derive_slug() {
  # lowercase, spaces → hyphens, strip non [a-z0-9-], collapse repeats,
  # trim leading/trailing hyphens. Portable (no ${var,,}).
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' \
    | tr -cd 'a-z0-9-' \
    | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

if [[ -z "$slug" ]]; then
  slug=$(derive_slug "$title")
fi
[[ -n "$slug" ]] || nyann::die "could not derive a slug from title; pass --slug"

if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  nyann::die "slug must match ^[a-z0-9][a-z0-9-]*\$: got '$slug'"
fi

# --- compute next number -----------------------------------------------------

next_num=0
if [[ -d "$abs_dir" ]]; then
  # Files named ADR-<3 digits>-*.md
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    bn=$(basename "$f")
    # Extract the 3-digit number.
    if [[ "$bn" =~ ^ADR-([0-9]{3})- ]]; then
      n=$((10#${BASH_REMATCH[1]}))
      (( n >= next_num )) && next_num=$((n + 1))
    fi
  done < <(find "$abs_dir" -maxdepth 1 -type f -name 'ADR-*.md' 2>/dev/null | sort)
fi
printf -v num3 "%03d" "$next_num"

out_rel="$dir/ADR-$num3-$slug.md"
out_abs="$target/$out_rel"

emit_json() {
  # $1=dry_run bool as string
  jq -n \
    --arg path "$out_rel" \
    --argjson number "$next_num" \
    --arg title "$title" \
    --arg status "$status" \
    --arg date "$date_str" \
    --arg slug "$slug" \
    --argjson dry_run "$1" \
    '{path:$path, number:$number, title:$title, status:$status, date:$date, slug:$slug, dry_run:$dry_run}'
}

# --- refuse overwrite --------------------------------------------------------

if [[ -e "$out_abs" ]]; then
  nyann::die "ADR path already exists: $out_rel (increment slug or pick a different --slug)"
fi

# --- render template ---------------------------------------------------------

template_path="${_script_dir}/../templates/docs/decisions/ADR-template.md"
[[ -f "$template_path" ]] || nyann::die "template missing: $template_path"

if $dry_run; then
  emit_json "true"
  exit 0
fi

mkdir -p "$abs_dir"

# Substitute placeholders.
#   {ADR-NNN}      → ADR-<num3>   (num3 is a formatted number)
#   YYYY-MM-DD     → "$date_str"  (validated ISO date)
#   status: proposed → status: <status>  (validated enum)
# Those three are safe to sed-substitute. $title is user-supplied and can
# legitimately contain /, \, &, or newlines — all of which either corrupt
# or crash sed on the replacement side. Pipe through perl, passing the
# title via env var so it never reaches the replacement parser.
rendered=$(sed \
  -e "s/{ADR-NNN}/ADR-$num3/g" \
  -e "s/^date: YYYY-MM-DD/date: $date_str/" \
  -e "s/^status: proposed/status: $status/" \
  "$template_path" \
  | TITLE="$title" perl -pe 's/\{title\}/$ENV{TITLE}/g')

[[ -L "$out_abs" ]] && nyann::die "refusing to write ADR via symlink: $out_abs"
printf '%s\n' "$rendered" > "$out_abs"

emit_json "false"
