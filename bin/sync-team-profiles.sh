#!/usr/bin/env bash
# sync-team-profiles.sh — clone/update team-profile sources and register
# discovered profiles under a namespace.
#
# Usage:
#   sync-team-profiles.sh [--user-root <dir>] [--force] [--name <source>]
#
# For each team_profile_sources[] entry:
#   - If last_synced_at + sync_interval_hours < now or --force:
#     - First run: `git clone --depth=1 --branch <ref>` into
#       <user-root>/cache/<source-name>/.
#     - Subsequent runs: `git fetch --depth=1 origin -- <ref>` then
#       `git reset --hard FETCH_HEAD` to advance to the latest
#       commit on <ref>.
#   - Enumerate profiles under the cache, validate each against
#     profiles/_schema.json, and emit a registration record.
#
# Output: JSON summary on stdout describing what synced / what was
# registered / any validation failures.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

# config.json may contain `https://<token>@host/...` and the cached
# repo's .git/config inherits the remote URL. Restrict everything we
# create to owner-only so other local users can't read tokens.
umask 0077

nyann::require_cmd jq
nyann::require_cmd git

user_root="${HOME}/.claude/nyann"
force=false
only_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    --force)       force=true; shift ;;
    --name)        only_name="${2:-}"; shift 2 ;;
    --name=*)      only_name="${1#--name=}"; shift ;;
    -h|--help)     sed -n '3,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

config="$user_root/config.json"
[[ -f "$config" ]] || { jq -n '{synced:[], skipped:[], registered:[], invalid:[]}'; exit 0; }

now=$(date +%s)
synced_json='[]'
skipped_json='[]'
registered_json='[]'
invalid_json='[]'

# Shared per-iteration error buffer. Created once, truncated before each
# git fetch/clone so stale output from a prior source never leaks into
# the next error report.
sync_err=$(mktemp -t nyann-sync.XXXXXX)

# Single EXIT cleanup that unwinds both the sync_err temp *and* any
# per-iteration lockdir still held. The previous code trapped only the
# temp; a `jq`/`mv` failure between `nyann::lock` and the explicit
# `nyann::unlock` (both under `set -e`) left the lockdir behind. Every
# subsequent `sync` run then waited the full 10s lock timeout and died.
# Now the trap fires on any non-happy exit and the `_held_lockdir` flag
# is kept in sync with the actual lock state.
_held_lockdir=""
_sync_cleanup() {
  # nyann::lock writes `$lockdir/owner` on acquire, so a bare `rmdir`
  # here would fail on a held lock. Delegate to
  # nyann::unlock which removes the owner file first. Still guarded
  # by the `_held_lockdir` flag so the trap only touches state we
  # actually owned.
  if [[ -n "${_held_lockdir:-}" ]]; then
    nyann::unlock "$_held_lockdir"
  fi
  rm -f "$sync_err"
}
trap _sync_cleanup EXIT

# Iterate sources. Single jq pass emits one TSV row per source with all
# five fields; previously each iteration spawned 5 jq processes for
# field-by-field unpacking (e.g. 4 sources = 20 jq forks just to read
# the config). Note: source `name`, `url`, and `ref` are validated
# against allowlist regexes in the loop body — none of them can contain
# tabs or newlines that would break TSV parsing.
cache_root="$user_root/cache"
while IFS=$'\t' read -r name url ref interval last; do
  [[ -z "$name" ]] && continue

  # Re-validate `name` on read. add-team-source.sh already enforces the
  # regex, but config.json is a plain file; a hand-edited entry like
  # {"name":"../Works/important-repo"} would otherwise let `git reset
  # --hard FETCH_HEAD` loose on an unrelated repo at $cache_root/../...
  if ! nyann::valid_profile_name "$name"; then
    invalid_json=$(jq --arg n "$name" --arg err "invalid source name (must match ^[a-z0-9][a-z0-9-]*$)" \
      '. + [{name:$n, kind:"invalid-name", error:$err}]' <<<"$invalid_json")
    continue
  fi

  # Re-validate ref + url on read. config.json is editable by hand
  # and someone may ship an older config with a value like
  # `--upload-pack=cmd` or `ext::evil-cmd %G`. Without this guard,
  # git fetch/clone below would parse the ref as an option or the
  # url as a command-executing transport.
  if ! nyann::valid_git_ref "$ref"; then
    invalid_json=$(jq --arg n "$name" --arg err "invalid ref" \
      '. + [{name:$n, kind:"invalid-ref", error:$err}]' <<<"$invalid_json")
    continue
  fi
  if ! nyann::valid_git_url "$url"; then
    invalid_json=$(jq --arg n "$name" --arg err "url scheme not allowlisted (https/ssh/git@)" \
      '. + [{name:$n, kind:"invalid-url", error:$err}]' <<<"$invalid_json")
    continue
  fi

  if [[ -n "$only_name" && "$only_name" != "$name" ]]; then
    continue
  fi

  # Belt-and-suspenders: even with the regex check above, confirm the
  # computed cache_dir canonicalises to a descendant of $cache_root.
  # Cheap to do once per source; covers future refactors where the
  # regex might get loosened.
  mkdir -p "$cache_root"
  cache_dir="$cache_root/$name"
  if ! nyann::path_under_target "$cache_root" "$cache_dir" >/dev/null; then
    invalid_json=$(jq --arg n "$name" --arg err "cache_dir escapes cache_root" \
      '. + [{name:$n, kind:"invalid-name", error:$err}]' <<<"$invalid_json")
    continue
  fi
  next_due=$(( last + interval * 3600 ))

  should_sync=false
  if $force; then
    should_sync=true
  elif (( now >= next_due )); then
    should_sync=true
  elif [[ ! -d "$cache_dir/.git" ]]; then
    should_sync=true
  fi

  if ! $should_sync; then
    skipped_json=$(jq --arg n "$name" --argjson due "$next_due" '
      . + [{name:$n, reason:"within-interval", next_due:$due}]
    ' <<<"$skipped_json")
    continue
  fi

  : > "$sync_err"
  # Re-resolve cache_dir immediately before each git -C so a racing
  # process that replaces the dir with a symlink between our
  # path_under_target check (far above) and this git invocation can't
  # redirect operations to an unrelated repo.
  if [[ -d "$cache_dir/.git" ]]; then
    resolved_cache=$(nyann::path_under_target "$cache_root" "$cache_dir") \
      || resolved_cache=""
    if [[ -z "$resolved_cache" ]]; then
      invalid_json=$(jq --arg n "$name" --arg err "cache_dir escapes cache_root (re-check before git)" \
        '. + [{name:$n, kind:"toctou", error:$err}]' <<<"$invalid_json")
      continue
    fi
    # Pin defensive git config for every team-source operation:
    #   protocol.allow=user / protocol.ext.allow=never — block git's
    #     `ext::` transport which executes arbitrary shell. Belt to
    #     valid_git_url's allowlist (which only checks the top-level
    #     URL — submodule URLs in the cloned repo aren't covered).
    #   protocol.file.allow=user — file:// already restricted by git
    #     ≥2.38 by default; pin it so older git stays safe.
    #   core.hooksPath=/dev/null — neutralise any post-fetch /
    #     post-checkout hook checked into the team repo's .githooks/.
    #   submodule.recurse=false — defensive even though `git fetch`
    #     does not recurse by default.
    git_safe=(-c protocol.allow=user -c protocol.ext.allow=never \
              -c protocol.file.allow=user \
              -c core.hooksPath=/dev/null -c submodule.recurse=false)
    if ! git "${git_safe[@]}" -C "$resolved_cache" fetch --depth=1 --no-recurse-submodules origin -- "$ref" >"$sync_err" 2>&1; then
      # Redact creds from any URL that may appear in stderr.
      err_msg=$(nyann::redact_url "$(head -c 500 "$sync_err" | tr '\n' ' ')")
      invalid_json=$(jq --arg n "$name" --arg err "$err_msg" '. + [{name:$n, kind:"fetch-failed", error:$err}]' <<<"$invalid_json")
      continue
    fi
    git "${git_safe[@]}" -C "$resolved_cache" reset --hard FETCH_HEAD >/dev/null 2>&1
  else
    # Fresh clone: resolution against cache_root (parent exists) is
    # what matters — the target dir doesn't exist yet. Use the
    # already-validated $cache_dir; git clone refuses to overwrite
    # an existing dir.
    git_safe=(-c protocol.allow=user -c protocol.ext.allow=never \
              -c protocol.file.allow=user \
              -c core.hooksPath=/dev/null -c submodule.recurse=false)
    if ! git "${git_safe[@]}" clone --depth=1 --no-recurse-submodules --branch "$ref" -- "$url" "$cache_dir" >"$sync_err" 2>&1; then
      err_msg=$(nyann::redact_url "$(head -c 500 "$sync_err" | tr '\n' ' ')")
      invalid_json=$(jq --arg n "$name" --arg err "$err_msg" '. + [{name:$n, kind:"clone-failed", error:$err}]' <<<"$invalid_json")
      continue
    fi
  fi

  synced_json=$(jq --arg n "$name" --argjson now "$now" '. + [{name:$n, synced_at:$now}]' <<<"$synced_json")

  # Update last_synced_at under a portable mkdir-based lock. Pair every
  # lock with the _held_lockdir flag so the EXIT trap can clean up if
  # jq/mv dies under `set -e` before we reach the explicit unlock.
  # Previously the lockdir leaked on any error in this block and blocked
  # future sync runs for 10s before dying.
  lockdir="${config}.lockdir"
  nyann::lock "$lockdir" 10
  _held_lockdir="$lockdir"
  tmp_cfg=$(mktemp "${config}.XXXXXX") \
    || { nyann::unlock "$lockdir"; _held_lockdir=""; nyann::die "mktemp failed for $config"; }
  jq --arg n "$name" --argjson now "$now" '
    .team_profile_sources = (.team_profile_sources | map(
      if .name == $n then . + {last_synced_at: $now} else . end
    ))
  ' "$config" > "$tmp_cfg"
  mv "$tmp_cfg" "$config"
  chmod 0600 "$config" 2>/dev/null || true
  nyann::unlock "$lockdir"
  _held_lockdir=""

  # Register profiles.
  shopt -s nullglob
  for pf in "$cache_dir"/profiles/*.json "$cache_dir"/*.json; do
    [[ -f "$pf" ]] || continue
    pname=$(basename "$pf" .json)
    [[ "$pname" == "_schema" ]] && continue
    if "${_script_dir}/validate-profile.sh" "$pf" >/dev/null 2>&1; then
      registered_json=$(jq --arg s "$name" --arg p "$pname" --arg path "$pf" '. + [{source:$s, name:$p, namespaced:($s+"/"+$p), path:$path}]' <<<"$registered_json")
    else
      invalid_json=$(jq --arg s "$name" --arg p "$pname" --arg path "$pf" '. + [{source:$s, name:$p, path:$path, kind:"invalid-schema"}]' <<<"$invalid_json")
    fi
  done
  shopt -u nullglob
done < <(jq -r '
  (.team_profile_sources // [])[]
  | [.name, .url, (.ref // "main"), (.sync_interval_hours // 24), (.last_synced_at // 0)]
  | @tsv
' "$config")

jq -n \
  --argjson synced "$synced_json" \
  --argjson skipped "$skipped_json" \
  --argjson registered "$registered_json" \
  --argjson invalid "$invalid_json" \
  '{synced:$synced, skipped:$skipped, registered:$registered, invalid:$invalid}'
