#!/usr/bin/env bash
# reorganize-docs.sh — move/rename docs to follow nyann conventions.
#
# Usage:
#   reorganize-docs.sh --target <repo> --moves <moves.json> [--apply]
#
# Reads a JSON array of approved moves (output of detect-doc-conformance.sh,
# possibly filtered by the user) and executes them. Uses `git mv` when
# inside a git repo, plain `mv` otherwise.
#
# Preview-before-mutate (default): without --apply, prints the planned
# moves and exits without touching the filesystem. Pass --apply (or --yes)
# to actually perform the moves.
#
# Safety:
#   - Refuses to overwrite existing targets
#   - Refuses to move through symlinks
#   - Validates all paths stay under --target
#
# Exit codes:
#   0 — all moves completed (or preview rendered)
#   1 — bad input
#   2 — one or more moves failed (partial success)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
moves_path=""
dry_run=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2:-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --moves)      moves_path="${2:-}"; shift 2 ;;
    --moves=*)    moves_path="${1#--moves=}"; shift ;;
    --apply)      dry_run=false; shift ;;
    --yes)        dry_run=false; shift ;;
    --dry-run)    dry_run=true; shift ;;  # explicit; matches default but accepted for clarity
    -h|--help)    sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target must be an existing directory"
[[ -n "$moves_path" && -f "$moves_path" ]] || nyann::die "--moves must point to an existing JSON file"
target="$(cd "$target" && pwd)"

moves_json="$(cat "$moves_path")" || nyann::die "cannot read moves file: $moves_path"
moves_type=$(jq -r 'type' <<<"$moves_json" 2>/dev/null) || nyann::die "moves file is not valid JSON: $moves_path"
[[ "$moves_type" == "array" ]] || nyann::die "moves file must be a JSON array; got: $moves_type"
move_count=$(jq 'length' <<<"$moves_json")

if (( move_count == 0 )); then
  nyann::log "no moves to execute"
  exit 0
fi

# Detect whether we're in a git repo
use_git=false
if [[ -d "$target/.git" ]] && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  use_git=true
fi

success_count=0
fail_count=0

for (( i=0; i<move_count; i++ )); do
  entry=$(jq -c ".[$i]" <<<"$moves_json")
  source_rel=$(jq -r '.source' <<<"$entry")
  target_rel=$(jq -r '.target' <<<"$entry")
  category=$(jq -r '.category' <<<"$entry")

  source_abs="$target/$source_rel"
  target_abs="$target/$target_rel"

  # Validate: no path traversal
  if [[ "$source_rel" == /* || "$source_rel" == *".."* ]]; then
    nyann::warn "skip: unsafe source path '$source_rel'"
    fail_count=$((fail_count + 1))
    continue
  fi
  if [[ "$target_rel" == /* || "$target_rel" == *".."* ]]; then
    nyann::warn "skip: unsafe target path '$target_rel'"
    fail_count=$((fail_count + 1))
    continue
  fi
  if ! nyann::assert_path_under_target "$target" "$source_abs" "source" 2>/dev/null; then
    nyann::warn "skip: source path escapes target: $source_rel"
    fail_count=$((fail_count + 1))
    continue
  fi
  if ! nyann::assert_path_under_target "$target" "$target_abs" "target" 2>/dev/null; then
    nyann::warn "skip: target path escapes target: $target_rel"
    fail_count=$((fail_count + 1))
    continue
  fi

  # Source must exist
  if [[ ! -e "$source_abs" ]]; then
    nyann::warn "skip: source does not exist: $source_rel"
    fail_count=$((fail_count + 1))
    continue
  fi

  # Target must NOT exist
  if [[ -e "$target_abs" ]]; then
    nyann::warn "skip: target already exists: $target_rel (won't overwrite)"
    fail_count=$((fail_count + 1))
    continue
  fi

  # No symlinks
  if [[ -L "$source_abs" ]]; then
    nyann::warn "skip: source is a symlink: $source_rel"
    fail_count=$((fail_count + 1))
    continue
  fi
  if [[ -L "$target_abs" ]]; then
    nyann::warn "skip: target is a symlink: $target_rel"
    fail_count=$((fail_count + 1))
    continue
  fi

  if $dry_run; then
    nyann::log "[dry-run] would move: $source_rel → $target_rel ($category)"
    success_count=$((success_count + 1))
    continue
  fi

  # Create target directory
  if ! mkdir -p "$(dirname "$target_abs")" 2>/dev/null; then
    nyann::warn "mkdir failed for $(dirname "$target_rel"): $source_rel → $target_rel"
    fail_count=$((fail_count + 1))
    continue
  fi

  # Execute move
  if $use_git; then
    if git -C "$target" ls-files --error-unmatch "$source_rel" >/dev/null 2>&1; then
      git -C "$target" mv "$source_rel" "$target_rel" 2>&1 || {
        nyann::warn "git mv failed: $source_rel → $target_rel"
        fail_count=$((fail_count + 1))
        continue
      }
    else
      mv "$source_abs" "$target_abs" || {
        nyann::warn "mv failed: $source_rel → $target_rel"
        fail_count=$((fail_count + 1))
        continue
      }
    fi
  else
    mv "$source_abs" "$target_abs" || {
      nyann::warn "mv failed: $source_rel → $target_rel"
      fail_count=$((fail_count + 1))
      continue
    }
  fi

  nyann::log "moved: $source_rel → $target_rel"
  success_count=$((success_count + 1))
done

if $dry_run; then
  nyann::log "preview only: $success_count would move, $fail_count would skip (re-run with --apply to execute)"
else
  nyann::log "reorganization complete: $success_count moved, $fail_count skipped"
fi

if (( fail_count > 0 )); then
  exit 2
fi
