#!/usr/bin/env bash
# add-team-source.sh — declare a team-profile remote in ~/.claude/nyann/config.json.
#
# Usage:
#   add-team-source.sh --name <id> --url <git-url> [--ref <branch>] [--interval <hours>]
#                      [--user-root <dir>]
#
# Writes to <user-root>/config.json (default ~/.claude/nyann/config.json).
# Duplicate `name` → updates the existing entry in place.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

# config.json can contain `https://<token>@host/...` URLs. Restrict
# the file (and its parent dir) to owner-only so other shell users
# on the same machine can't read credentials.
umask 0077

nyann::require_cmd jq

name=""
url=""
ref="main"
interval=24
user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         name="${2:-}"; shift 2 ;;
    --name=*)       name="${1#--name=}"; shift ;;
    --url)          url="${2:-}"; shift 2 ;;
    --url=*)        url="${1#--url=}"; shift ;;
    --ref)          ref="${2:-main}"; shift 2 ;;
    --ref=*)        ref="${1#--ref=}"; shift ;;
    --interval)     interval="${2:-24}"; shift 2 ;;
    --interval=*)   interval="${1#--interval=}"; shift ;;
    --user-root)    user_root="${2:-}"; shift 2 ;;
    --user-root=*)  user_root="${1#--user-root=}"; shift ;;
    -h|--help)      sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$name" ]] || nyann::die "--name is required"
[[ -n "$url" ]]  || nyann::die "--url is required"

if ! nyann::valid_profile_name "$name"; then
  nyann::die "--name must match ^[a-z0-9][a-z0-9-]*\$"
fi

# Validate --ref and --url at the write path. A crafted --ref like
# `--upload-pack=cmd`, or a --url using git's ext:: transport, would
# let a later sync/drift-check invoke git with flag-like arguments or
# code-executing transports. Same checks re-run on read for
# defence-in-depth.
if ! nyann::valid_git_ref "$ref"; then
  nyann::die "--ref rejected (must be ^[A-Za-z0-9_./:-]+\$, no leading '-'): $ref"
fi
if ! nyann::valid_git_url "$url"; then
  nyann::die "--url scheme not allowlisted (must be https/http/ssh/git/git@/file, no leading '-', no ext::): $(nyann::redact_url "$url")"
fi

mkdir -p "$user_root"
chmod 0700 "$user_root" 2>/dev/null || true
config="$user_root/config.json"

# Serialize the read-modify-write via an atomic mkdir lock.
# `mkdir` is a portable atomic primitive across macOS (no flock) and
# Linux; the alternatives (`flock`, file descriptors via `{var}>`) are
# either Linux-only or require bash ≥ 4.1 which macOS doesn't ship.
lockdir="${config}.lockdir"
nyann::lock "$lockdir" 10
trap 'nyann::unlock "$lockdir"' EXIT

if [[ -f "$config" ]]; then
  current=$(cat "$config")
else
  current='{"schemaVersion":1,"team_profile_sources":[]}'
fi

# Idempotent upsert: if a source with the same name exists, replace it.
updated=$(jq --arg name "$name" --arg url "$url" --arg ref "$ref" --argjson interval "$interval" '
  . as $cfg
  | ($cfg.team_profile_sources // []) as $srcs
  | ($srcs | map(select(.name != $name))) as $others
  | ($others + [{ name: $name, url: $url, ref: $ref, sync_interval_hours: $interval }]) as $new
  | { schemaVersion: ($cfg.schemaVersion // 1), team_profile_sources: $new }
' <<<"$current")

# Atomic write via mktemp + rename so a crash doesn't leave a truncated
# config. mktemp inherits umask 0077 so the temp is already 0600.
tmp_config=$(mktemp "${config}.XXXXXX") \
  || nyann::die "mktemp failed for $config"
printf '%s\n' "$updated" > "$tmp_config"
mv "$tmp_config" "$config"
chmod 0600 "$config" 2>/dev/null || true

# Explicit unlock; EXIT trap also covers error paths.
nyann::unlock "$lockdir"

nyann::log "wrote $config"
