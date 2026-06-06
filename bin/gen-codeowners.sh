#!/usr/bin/env bash
set -euo pipefail
# gen-codeowners.sh — generate .github/CODEOWNERS from workspace configs.
#
# Usage:
#   gen-codeowners.sh --workspace-configs <path> --target <repo>
#                     [--default-owner <handle>] [--dry-run]
#
# Reads workspace configs JSON (from resolve-workspace-configs.sh),
# maps each workspace path to an owner. Generates .github/CODEOWNERS
# between marker comments for idempotent regeneration.
#
# Non-monorepo repos: exit 0 silently (not an error).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
ws_configs_path=""
default_owner="*"
dry_run=false
profile_owners_path=""
derived_owners_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)             target="${2:-}"; shift 2 ;;
    --target=*)           target="${1#--target=}"; shift ;;
    --workspace-configs)  ws_configs_path="${2:-}"; shift 2 ;;
    --workspace-configs=*) ws_configs_path="${1#--workspace-configs=}"; shift ;;
    --profile-owners)     profile_owners_path="${2:-}"; shift 2 ;;
    --profile-owners=*)   profile_owners_path="${1#--profile-owners=}"; shift ;;
    --derived-owners)     derived_owners_path="${2:-}"; shift 2 ;;
    --derived-owners=*)   derived_owners_path="${1#--derived-owners=}"; shift ;;
    --default-owner)      default_owner="${2:-*}"; shift 2 ;;
    --default-owner=*)    default_owner="${1#--default-owner=}"; shift ;;
    --dry-run)            dry_run=true; shift ;;
    -h|--help)            sed -n '3,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
target="$(cd "$target" && pwd)"

has_ws=false
if [[ -n "$ws_configs_path" && -f "$ws_configs_path" ]]; then
  ws_count=$(jq 'length' "$ws_configs_path" 2>/dev/null || echo 0)
  if [[ "$ws_count" -gt 0 ]]; then
    has_ws=true
  fi
fi

has_profile_owners=false
if [[ -n "$profile_owners_path" && -f "$profile_owners_path" ]]; then
  po_count=$(jq 'length' "$profile_owners_path" 2>/dev/null || echo 0)
  if [[ "$po_count" -gt 0 ]]; then
    has_profile_owners=true
  fi
fi

has_derived=false
if [[ -n "$derived_owners_path" && -f "$derived_owners_path" ]]; then
  has_derived=true
fi

if ! $has_ws && ! $has_profile_owners && ! $has_derived; then
  nyann::log "no ownership sources — skipping CODEOWNERS"
  exit 0
fi

# --- Build CODEOWNERS content ------------------------------------------------

MARKER_START="# nyann:codeowners:start"
MARKER_END="# nyann:codeowners:end"

codeowners_lines=""

# Layer 1: workspace owners (lowest precedence in CODEOWNERS — listed first)
if $has_ws; then
  while IFS= read -r ws_entry; do
    ws_path=$(jq -r '.path' <<<"$ws_entry")
    ws_owner=$(jq -r '.owner // ""' <<<"$ws_entry")
    [[ -z "$ws_path" ]] && continue
    if [[ -z "$ws_owner" || "$ws_owner" == "null" ]]; then
      ws_owner="$default_owner"
    fi
    codeowners_lines="${codeowners_lines}${ws_path}/ ${ws_owner}"$'\n'
  done < <(jq -c '.[]' "$ws_configs_path")
fi

# Layer 2: derived owners from git history (middle precedence).
# derive-codeowners.sh emits suggested_owner="" when it couldn't map the
# top committer to a CODEOWNERS-valid owner (@handle / @org/team /
# email). A bare display name must never be written as an active owner —
# GitHub rejects it and the rule is silently inert. So: emit an active
# rule only when suggested_owner is non-empty; otherwise drop a
# `# suggested:` comment naming the top committer for manual handle
# assignment (no inert rule reaches the file).
if $has_derived; then
  # Read one entry per line (NDJSON) and pull each field with jq. A
  # tab-joined @tsv won't work here: an empty suggested_owner field
  # produces consecutive tabs, and `read` with a whitespace IFS (tab is
  # whitespace) collapses them — shifting the name into the owner slot
  # and re-introducing the bare-name bug this code is meant to prevent.
  while IFS= read -r d_entry; do
    [[ -z "$d_entry" ]] && continue
    d_path=$(jq -r '.path // ""' <<<"$d_entry")
    d_owner=$(jq -r '.suggested_owner // ""' <<<"$d_entry")
    d_name=$(jq -r '.suggested_name // ""' <<<"$d_entry")
    [[ -z "$d_path" || "$d_path" == "null" ]] && continue
    if [[ -n "$d_owner" && "$d_owner" != "null" ]]; then
      codeowners_lines="${codeowners_lines}${d_path} ${d_owner}"$'\n'
    elif [[ -n "$d_name" && "$d_name" != "null" ]]; then
      codeowners_lines="${codeowners_lines}# suggested: ${d_path} — top committer \"${d_name}\"; assign a @handle or @org/team manually"$'\n'
    fi
  done < <(jq -c '.[]' "$derived_owners_path" 2>/dev/null)
fi

# Layer 3: explicit profile owners (highest precedence — listed last, CODEOWNERS uses last-match-wins).
# Guard two ways a malformed entry would otherwise corrupt the output:
#   - missing `owners` → jq `.owners | join(...)` raises "Cannot iterate
#     over null" (exit 5) and aborts the script. `.owners // []` makes it
#     an empty join, which we then skip.
#   - missing `pattern` → jq -r prints the literal string "null", which a
#     `-z` test won't catch, producing a bogus `null @owner` rule. Reject
#     empty AND the literal "null" explicitly.
if $has_profile_owners; then
  while IFS= read -r po_entry; do
    po_pattern=$(jq -r '.pattern // ""' <<<"$po_entry")
    po_owners=$(jq -r '.owners // [] | join(" ")' <<<"$po_entry")
    [[ -z "$po_pattern" || "$po_pattern" == "null" ]] && continue
    [[ -z "$po_owners" ]] && continue
    codeowners_lines="${codeowners_lines}${po_pattern} ${po_owners}"$'\n'
  done < <(jq -c '.[]' "$profile_owners_path")
fi

marked_content="${MARKER_START}
# Generated by nyann — do not edit between these markers.
# Workspace → owner mapping from profile workspaces.<path>.owner.
${codeowners_lines}${MARKER_END}"

if [[ "$dry_run" == "true" ]]; then
  printf '%s\n' "$marked_content"
  exit 0
fi

# --- Write CODEOWNERS (marker-idempotent) ------------------------------------

co_path="$target/.github/CODEOWNERS"
[[ -L "$co_path" ]] && nyann::die "refusing to write CODEOWNERS via symlink: $co_path"
mkdir -p "$(dirname "$co_path")"

if [[ -f "$co_path" ]]; then
  if grep -Fq "$MARKER_START" "$co_path" && grep -Fq "$MARKER_END" "$co_path"; then
    new_content_file=$(mktemp -t nyann-co-new.XXXXXX)
    co_tmp=$(mktemp -t nyann-co-out.XXXXXX)
    trap 'rm -f "$new_content_file" "$co_tmp"' EXIT
    printf '%s\n' "$marked_content" > "$new_content_file"
    awk -v ms="$MARKER_START" -v me="$MARKER_END" -v nf="$new_content_file" '
      $0 == ms { while ((getline line < nf) > 0) print line; close(nf); skip=1; next }
      $0 == me { skip=0; next }
      !skip { print }
    ' "$co_path" > "$co_tmp"
    rm -f "$new_content_file"
    mv "$co_tmp" "$co_path"
    nyann::log "regenerated CODEOWNERS (markers preserved): $co_path"
  else
    printf '\n%s\n' "$marked_content" >> "$co_path"
    nyann::log "appended CODEOWNERS block to existing file: $co_path"
  fi
else
  printf '%s\n' "$marked_content" > "$co_path"
  nyann::log "created CODEOWNERS: $co_path"
fi
