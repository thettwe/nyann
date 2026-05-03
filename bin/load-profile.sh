#!/usr/bin/env bash
# load-profile.sh — resolve and load a nyann profile by name.
#
# Usage: load-profile.sh <name> [--user-root <dir>] [--plugin-root <dir>]
#
# Resolution order (user > team > starter):
#   1. $user_root/profiles/<name>.json                 (user overrides)
#   2. $user_root/cache/<source>/profiles/<name>.json  (team sources)
#      A namespaced name `source/name` forces the team version even
#      when a user profile shadows it.
#   3. $plugin_root/profiles/<name>.json               (starter profiles)
#
# Validates the chosen file via bin/validate-profile.sh. On success, emits the
# profile JSON to stdout (canonical pretty). Logs the resolved source to
# stderr so callers know which layer won.
#
# Exit codes:
#   0 — found and valid
#   2 — profile not found in any tier (stderr lists what's available)
#   4 — profile found but fails schema validation

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

plugin_root="$(cd "${_script_dir}/.." && pwd)"
user_root="${HOME}/.claude/nyann"

name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)     user_root="${2:-}"; shift 2 ;;
    --user-root=*)   user_root="${1#--user-root=}"; shift ;;
    --plugin-root)   plugin_root="${2:-}"; shift 2 ;;
    --plugin-root=*) plugin_root="${1#--plugin-root=}"; shift ;;
    -h|--help)
      sed -n '3,22p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    --*) nyann::die "unknown flag: $1" ;;
    *)
      [[ -z "$name" ]] || nyann::die "unexpected extra arg: $1 (name already set to $name)"
      name="$1"; shift
      ;;
  esac
done

[[ -n "$name" ]] || nyann::die "usage: load-profile.sh <name>"

# Name shape: bare `profile-name`, OR namespaced `team-source/profile-name`.
# Each segment must match the same regex add-team-source.sh enforces so a
# caller cannot smuggle `..` or path separators into the filesystem lookup
# below.
if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)?$ ]]; then
  nyann::die "invalid profile name: $name (must be [a-z0-9][a-z0-9-]* or team/[a-z0-9][a-z0-9-]*)"
fi

list_available() {
  local root label n
  for pair in "${user_root}/profiles:user" "${plugin_root}/profiles:starter"; do
    root="${pair%:*}"; label="${pair#*:}"
    [[ -d "$root" ]] || continue
    shopt -s nullglob
    for f in "$root"/*.json; do
      n="$(basename "$f" .json)"
      [[ "$n" == "_schema" ]] && continue
      printf '  - %s  (%s)\n' "$n" "$label"
    done
    shopt -u nullglob
  done
  # Team sources live under $user_root/cache/<source>/profiles/ OR directly
  # under $user_root/cache/<source>/.
  if [[ -d "${user_root}/cache" ]]; then
    shopt -s nullglob
    for srcdir in "${user_root}/cache"/*; do
      [[ -d "$srcdir" ]] || continue
      local src
      src="$(basename "$srcdir")"
      for f in "$srcdir"/profiles/*.json "$srcdir"/*.json; do
        [[ -f "$f" ]] || continue
        n="$(basename "$f" .json)"
        [[ "$n" == "_schema" ]] && continue
        printf '  - %s/%s  (team)\n' "$src" "$n"
      done
    done
    shopt -u nullglob
  fi
}

resolved=""
source_label=""

# Team-namespaced name (source/name) → look in that cache only.
if [[ "$name" == */* ]]; then
  src="${name%%/*}"
  pname="${name#*/}"
  for candidate in \
    "${user_root}/cache/${src}/profiles/${pname}.json" \
    "${user_root}/cache/${src}/${pname}.json"; do
    if [[ -f "$candidate" ]]; then
      resolved="$candidate"
      source_label="team:${src}"
      break
    fi
  done
else
  # Bare name: user → team → starter.
  user_path="${user_root}/profiles/${name}.json"
  plugin_path="${plugin_root}/profiles/${name}.json"
  team_hit=""
  if [[ -d "${user_root}/cache" ]]; then
    shopt -s nullglob
    for srcdir in "${user_root}/cache"/*; do
      [[ -d "$srcdir" ]] || continue
      for candidate in "$srcdir/profiles/${name}.json" "$srcdir/${name}.json"; do
        if [[ -f "$candidate" ]]; then
          team_hit="$candidate"
          break 2
        fi
      done
    done
    shopt -u nullglob
  fi

  if [[ -f "$user_path" ]]; then
    resolved="$user_path"; source_label="user"
  elif [[ -n "$team_hit" ]]; then
    resolved="$team_hit"; source_label="team:$(basename "$(dirname "$(dirname "$team_hit")")" 2>/dev/null || basename "$(dirname "$team_hit")")"
  elif [[ -f "$plugin_path" ]]; then
    resolved="$plugin_path"; source_label="starter"
  else
    nyann::warn "profile not found: ${name}"
    nyann::warn "searched:"
    nyann::warn "  $user_path"
    [[ -d "${user_root}/cache" ]] && nyann::warn "  ${user_root}/cache/*/{,/profiles/}${name}.json"
    nyann::warn "  $plugin_path"
    {
      printf '[nyann] available profiles:\n'
      list_available
    } >&2
    exit 2
  fi
fi

if [[ -z "$resolved" ]]; then
  nyann::warn "profile not found: ${name}"
  {
    printf '[nyann] available profiles:\n'
    list_available
  } >&2
  exit 2
fi

nyann::log "loading profile '${name}' from ${source_label}: ${resolved}"

# Collision detection. Computed once and surfaced two ways: as nyann::log
# lines (for direct CLI users + inspect-profile readers) AND as a
# structured _meta field on the emitted JSON below (so skill-layer
# callers can programmatically warn the user without scraping stderr).
shadowed_starter=""
shadowed_team_csv=""
if [[ "$source_label" == "user" ]]; then
  starter_candidate="${plugin_root}/profiles/${name}.json"
  if [[ -f "$starter_candidate" ]]; then
    shadowed_starter="$starter_candidate"
    nyann::log "user profile shadows starter at ${starter_candidate}"
  fi
  if [[ -d "${user_root}/cache" ]]; then
    shopt -s nullglob
    for srcdir in "${user_root}/cache"/*; do
      [[ -d "$srcdir" ]] || continue
      for cand in "$srcdir/profiles/${name}.json" "$srcdir/${name}.json"; do
        if [[ -f "$cand" ]]; then
          shadowed_team_csv="${shadowed_team_csv:+${shadowed_team_csv}\t}${cand}"
          nyann::log "user profile shadows team profile at ${cand}"
        fi
      done
    done
    shopt -u nullglob
  fi
fi

# Auto-migrate if the file is older than the current schema. migrate-profile.sh
# currently targets v1 (no-op), but the hook is live so a future v1→v2 bump
# just needs the migration filter + a bump of NYANN_CURRENT_SCHEMA in
# bin/_lib.sh — not a loader rewrite.
CURRENT_SCHEMA="$NYANN_CURRENT_SCHEMA"

# Always work from a mktemp'd copy of the resolved profile. Two wins:
#   1. Closes the validate/read TOCTOU — a concurrent swap between
#      validate-profile.sh and `jq '.' "$resolved"` would let
#      unvalidated JSON reach the caller. Reading a local copy once
#      makes the validated bytes and the emitted bytes identical by
#      construction.
#   2. Unifies the cleanup path. $tmp_resolved + $validate_err now
#      live in the same EXIT trap, so a non-zero exit can't orphan
#      the profile JSON (which may contain credentials) in /tmp.
tmp_resolved=$(mktemp -t nyann-load-resolved.XXXXXX)
validate_err=$(mktemp -t nyann-load-validate.XXXXXX)
trap 'rm -f "$tmp_resolved" "$validate_err"' EXIT

file_version=$(jq -r '.schemaVersion // 1' "$resolved" 2>/dev/null || echo 1)
if [[ "$file_version" =~ ^[0-9]+$ ]] && (( file_version < CURRENT_SCHEMA )); then
  nyann::log "profile at schemaVersion ${file_version}; auto-migrating to v${CURRENT_SCHEMA} in memory"
  migrated=$("${_script_dir}/migrate-profile.sh" "$resolved")
  printf '%s\n' "$migrated" > "$tmp_resolved"
else
  # Snapshot the resolved profile into tmp_resolved so validate + emit
  # operate on the same bytes even if $resolved is swapped concurrently.
  cp "$resolved" "$tmp_resolved"
fi

# Validate via validate-profile.sh against the snapshot.
# Starter profiles are immutable between plugin releases, so skip the
# expensive validator (uvx/check-jsonschema subprocess) when a version
# sentinel confirms they were already validated for this plugin version.
_skip_validation=false
if [[ "$source_label" == "starter" ]]; then
  _plugin_version=$(jq -r '.version // ""' "${_script_dir}/../.claude-plugin/plugin.json" 2>/dev/null || echo "")
  _sentinel_file="${plugin_root}/profiles/_validated_at_version"
  if [[ -n "$_plugin_version" && -f "$_sentinel_file" ]]; then
    _sentinel_version=$(<"$_sentinel_file")
    [[ "$_sentinel_version" == "$_plugin_version" ]] && _skip_validation=true
  fi
fi

if $_skip_validation; then
  nyann::log "starter profile validation skipped (sentinel matches v${_plugin_version})"
else
  "${_script_dir}/validate-profile.sh" "$tmp_resolved" >/dev/null 2>"$validate_err"
  vrc=$?
  if [[ $vrc -ne 0 ]]; then
    cat "$validate_err" >&2 || true
    nyann::warn "profile failed validation: ${resolved}"
    exit 4
  fi
  # Update sentinel on successful starter profile validation.
  if [[ "$source_label" == "starter" && -n "${_plugin_version:-}" ]]; then
    printf '%s' "$_plugin_version" > "${_sentinel_file:-}" 2>/dev/null || true
  fi
fi

# Inject _meta on emit. The JSON in $tmp_resolved is the validated
# profile; layering _meta after validation keeps the file-on-disk
# contract clean (no _meta in stored profiles) while letting
# downstream skill callers see resolution metadata without scraping
# stderr. Schema permits _meta as an optional top-level extension.
shadowed_team_json='[]'
if [[ -n "$shadowed_team_csv" ]]; then
  shadowed_team_json=$(printf '%s' "$shadowed_team_csv" | tr '\t' '\n' \
    | jq -R . | jq -s 'map(select(. != ""))')
fi
jq \
  --arg src "$source_label" \
  --arg src_path "$resolved" \
  --arg shadowed_starter "$shadowed_starter" \
  --argjson shadowed_team "$shadowed_team_json" \
  '. + {
     _meta: ({source: $src, source_path: $src_path}
       + (if $shadowed_starter != "" then {shadowed_starter: $shadowed_starter} else {} end)
       + (if ($shadowed_team | length) > 0 then {shadowed_team: $shadowed_team} else {} end))
   }' "$tmp_resolved"
