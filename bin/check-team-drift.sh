#!/usr/bin/env bash
# check-team-drift.sh — compare cached team profiles against remote.
#
# Usage:
#   check-team-drift.sh [--user-root <dir>] [--offline]
#
# For each configured team source, compare the hash of every locally-
# cached profile against the same profile on the remote ref. Emits JSON
# describing which profiles drifted so a skill can prompt the user.
#
# --offline skips all network calls and reports the currently-cached
# profile hashes only. The skill layer uses this to decide whether to
# offer a sync without making the check mandatory.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

user_root="${HOME}/.claude/nyann"
offline=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    --offline)     offline=true; shift ;;
    -h|--help)     sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

config="$user_root/config.json"
[[ -f "$config" ]] || { jq -n '{drift:[], up_to_date:[], unreachable:[]}'; exit 0; }

srcs_json=$(jq '.team_profile_sources // []' "$config")
count=$(jq 'length' <<<"$srcs_json")

# Compute SHA-256 of the JSON body (canonicalized via jq).
profile_hash() {
  local path="$1"
  jq -cS '.' "$path" 2>/dev/null | shasum -a 256 | awk '{print $1}'
}

drift_json='[]'
ok_json='[]'
unreachable_json='[]'

# Shared per-iteration error buffer, truncated before each fetch.
drift_err=$(mktemp -t nyann-drift.XXXXXX)
trap 'rm -f "$drift_err"' EXIT

cache_root="$user_root/cache"
for ((i = 0; i < count; i++)); do
  name=$(jq -r --arg i "$i" '.[$i|tonumber].name' <<<"$srcs_json")
  ref=$(jq -r --arg i "$i" '.[$i|tonumber].ref // "main"' <<<"$srcs_json")

  # Re-validate source name on read. A hand-edited config.json with
  # {"name":"../Works/important-repo"} would let `git -C "$cache_dir"
  # fetch` operate on an unrelated repo outside the cache root.
  if ! nyann::valid_profile_name "$name"; then
    unreachable_json=$(jq --arg s "$name" --arg err "invalid source name (must match ^[a-z0-9][a-z0-9-]*\$)" \
      '. + [{source:$s, error:$err}]' <<<"$unreachable_json")
    continue
  fi

  # Same ref-validation as sync-team-profiles.sh. A hand-edited ref
  # of `--upload-pack=cmd` would be parsed as a git option without
  # this guard.
  if ! nyann::valid_git_ref "$ref"; then
    unreachable_json=$(jq --arg s "$name" --arg err "invalid ref" \
      '. + [{source:$s, error:$err}]' <<<"$unreachable_json")
    continue
  fi

  cache_dir="$cache_root/$name"
  # Defence-in-depth: even with the regex check above, confirm the
  # computed cache_dir canonicalises under $cache_root.
  if ! nyann::path_under_target "$cache_root" "$cache_dir" >/dev/null; then
    unreachable_json=$(jq --arg s "$name" --arg err "cache_dir escapes cache_root" \
      '. + [{source:$s, error:$err}]' <<<"$unreachable_json")
    continue
  fi

  [[ -d "$cache_dir/.git" ]] || continue

  # Walk cached profiles.
  shopt -s nullglob
  for pf in "$cache_dir"/profiles/*.json "$cache_dir"/*.json; do
    [[ -f "$pf" ]] || continue
    pname=$(basename "$pf" .json)
    [[ "$pname" == "_schema" ]] && continue

    cached_hash=$(profile_hash "$pf")

    if $offline; then
      ok_json=$(jq --arg s "$name" --arg p "$pname" --arg h "$cached_hash" \
        '. + [{source:$s, name:$p, namespaced:($s+"/"+$p), cached_hash:$h}]' <<<"$ok_json")
      continue
    fi

    # Fetch remote (shallow, minimal) and compare.
    # Re-resolve cache_dir before `git -C` to close the TOCTOU window
    # since the path_under_target check (above).
    : > "$drift_err"
    resolved_cache=$(nyann::path_under_target "$cache_root" "$cache_dir") \
      || resolved_cache=""
    if [[ -z "$resolved_cache" ]]; then
      unreachable_json=$(jq --arg s "$name" --arg err "cache_dir escapes cache_root (re-check)" \
        '. + [{source:$s, error:$err}]' <<<"$unreachable_json")
      break
    fi
    # Same defensive git config as sync-team-profiles.sh: block ext::
    # transport, neutralise hooks, disable submodule recursion. See
    # sync-team-profiles.sh for rationale.
    git_safe=(-c protocol.allow=user -c protocol.ext.allow=never \
              -c protocol.file.allow=user \
              -c core.hooksPath=/dev/null -c submodule.recurse=false)
    if ! git "${git_safe[@]}" -C "$resolved_cache" fetch --quiet --depth=1 --no-recurse-submodules origin -- "$ref" 2>"$drift_err"; then
      # Redact embedded tokens from error text before logging.
      err_msg=$(nyann::redact_url "$(head -c 500 "$drift_err" | tr '\n' ' ')")
      unreachable_json=$(jq --arg s "$name" --arg err "$err_msg" '. + [{source:$s, error:$err}]' <<<"$unreachable_json")
      break  # bail this source, try the next
    fi

    # Relative path inside the repo for the profile.
    # Use cache_dir (not resolved_cache) for prefix stripping since the
    # glob-expanded pf shares the same prefix as cache_dir, while
    # resolved_cache may differ due to symlink resolution (e.g.
    # /var vs /private/var on macOS). Inner quoting on cache_dir
    # prevents glob-pattern interpretation when the path contains
    # shell metachars.
    rel="${pf#"${cache_dir}"/}"
    remote_blob=$(git -C "$resolved_cache" show "FETCH_HEAD:${rel}" 2>/dev/null || echo "")
    if [[ -z "$remote_blob" ]]; then
      # Profile exists locally but not remotely — treat as drift.
      drift_json=$(jq --arg s "$name" --arg p "$pname" --arg ch "$cached_hash" --arg rh "" --arg kind "removed-remotely" \
        '. + [{source:$s, name:$p, namespaced:($s+"/"+$p), cached_hash:$ch, remote_hash:$rh, kind:$kind}]' <<<"$drift_json")
      continue
    fi

    remote_hash=$(printf '%s' "$remote_blob" | jq -cS '.' 2>/dev/null | shasum -a 256 | awk '{print $1}')
    if [[ "$cached_hash" == "$remote_hash" ]]; then
      ok_json=$(jq --arg s "$name" --arg p "$pname" --arg h "$cached_hash" \
        '. + [{source:$s, name:$p, namespaced:($s+"/"+$p), cached_hash:$h}]' <<<"$ok_json")
    else
      drift_json=$(jq --arg s "$name" --arg p "$pname" --arg ch "$cached_hash" --arg rh "$remote_hash" --arg kind "remote-updated" \
        '. + [{source:$s, name:$p, namespaced:($s+"/"+$p), cached_hash:$ch, remote_hash:$rh, kind:$kind}]' <<<"$drift_json")
    fi
  done
  shopt -u nullglob
done

jq -n \
  --argjson drift "$drift_json" \
  --argjson ok "$ok_json" \
  --argjson unreachable "$unreachable_json" \
  '{drift:$drift, up_to_date:$ok, unreachable:$unreachable}'
