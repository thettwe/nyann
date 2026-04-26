#!/usr/bin/env bash
# migrate-profile.sh — up-convert a profile to the current schema version.
#
# Usage:
#   migrate-profile.sh <path>               # print migrated JSON to stdout
#   migrate-profile.sh --in-place <path>    # overwrite file in place
#
# Current schemaVersion is defined in bin/_lib.sh as NYANN_CURRENT_SCHEMA.
# Down-conversion is unsupported — a profile newer than our current
# version errors out.
#
# Migration registry: CURRENT defines the target; migrations are jq
# filters keyed by starting version. To add a v1→v2 bump, write the
# migration as a jq filter and wire it into the `migrate_step` case.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# Use the single NYANN_CURRENT_SCHEMA constant from _lib.sh rather
# than a locally-hardcoded value.
CURRENT="$NYANN_CURRENT_SCHEMA"

in_place=false
path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place) in_place=true; shift ;;
    -h|--help)  sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    --*)        nyann::die "unknown flag: $1" ;;
    *)
      [[ -z "$path" ]] || nyann::die "unexpected extra arg: $1"
      path="$1"; shift
      ;;
  esac
done

[[ -n "$path" && -f "$path" ]] || nyann::die "usage: migrate-profile.sh [--in-place] <path>"

body=$(cat "$path")
version=$(jq -r '.schemaVersion // 1' <<<"$body")

if ! [[ "$version" =~ ^[0-9]+$ ]]; then
  nyann::die "unknown schemaVersion in $path: $version"
fi

if (( version > CURRENT )); then
  nyann::die "profile schemaVersion $version is newer than this nyann supports ($CURRENT). Upgrade nyann."
fi

# Per-step migration filters. Each filter takes a v(N) profile and
# returns a v(N+1) profile; schemaVersion bump happens inside.
migrate_step() {
  # $1 = starting schemaVersion. The profile body is piped in on stdin.
  # When a v1→v2 case is added, read stdin and emit the upgraded JSON.
  local from_v="$1"
  case "$from_v" in
    # Example shape for the first real bump (v1 → v2). Unused while
    # CURRENT=1; kept so the mechanics are already plumbed. Add new
    # cases as schema evolves.
    # 1)
    #   jq '. as $p | $p + { schemaVersion: 2, some_new_field: "default" }' <<<"$doc_body"
    #   ;;
    *)
      # Unknown bump → fail loudly.
      nyann::die "no migration registered for v${from_v} → v$((from_v + 1))"
      ;;
  esac
}

# Walk up one version at a time. Pipe body via stdin to keep migrate_step
# params simple.
while (( version < CURRENT )); do
  body=$(migrate_step "$version" <<<"$body")
  version=$((version + 1))
done

# Final validation against the current schema, so a borked migration
# never escapes.
tmp=$(mktemp -t nyann-migrate.XXXXXX)
migrate_err=$(mktemp -t nyann-migrate-err.XXXXXX)
trap 'rm -f "$tmp" "$migrate_err"' EXIT
printf '%s\n' "$body" > "$tmp"
if ! "${_script_dir}/validate-profile.sh" "$tmp" >"$migrate_err" 2>&1; then
  nyann::warn "migrated profile fails current schema validation"
  cat "$migrate_err" >&2
  rm -f "$tmp"
  exit 4
fi

if $in_place; then
  mv "$tmp" "$path"
  nyann::log "migrated $path to schemaVersion $CURRENT"
else
  cat "$tmp"
  rm -f "$tmp"
fi
