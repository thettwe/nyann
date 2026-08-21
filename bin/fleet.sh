#!/usr/bin/env bash
# fleet.sh — manage the fleet registry of local repos.
#
# The registry is the shared data model behind the fleet verbs: bulk audit
# (bin/fleet-doctor.sh) and bulk remediation planning (bin/fleet-retrofit.sh)
# iterate it. It is DISTINCT from the sentinel watch-list: watch-list entries
# are GitHub slugs for remote CI polling, fleet entries are LOCAL working-copy
# paths for governance verbs. The optional `repo` slug on a fleet entry is the
# join key between the two (--watch mirrors it into the watch-list).
#
# Usage:
#   fleet.sh --add <path> [--name <n>] [--repo <owner/repo>] [--profile <p>]
#            [--tag <t>]... [--watch]
#   fleet.sh --remove <name|path>
#   fleet.sh --list
#   fleet.sh --scan <dir> [--depth <n>] [--apply]
#   fleet.sh --prune [--apply]
#   fleet.sh --suggest-org <org>
#
# Shared options (all modes):
#   --fleet-file <path>   registry JSON (default: ~/.claude/nyann/fleet.json)
#   --watch-list <path>   sentinel watch-list for --watch mirroring
#                         (default: ~/.claude/nyann/watch-list.json)
#
# Modes:
#   --add     Idempotently add a local git repo. The path is canonicalised to
#             the repo TOPLEVEL (so two adds at different depths can't create
#             duplicates). Re-adding an existing repo merges updates: new
#             --tag values union in (deduped), --repo / --profile / --name
#             overwrite when given. With --watch, additionally mirror the
#             entry's `repo` slug into the sentinel watch-list (slug from
#             --repo, else parsed from the origin remote; unresolvable →
#             warn + skip the mirror, the fleet add still succeeds).
#   --remove  Remove an entry by name or by path (no-op if absent). An
#             ambiguous name (two entries sharing it after a hand-edit) is
#             refused — remove by path instead.
#   --list    Print the registry as a JSON array (empty registry = []).
#   --scan    Discover git repos under <dir> (default depth 2, i.e. <dir>/*
#             and <dir>/*/*) and print the NOT-yet-registered candidates as a
#             JSON array on stdout (human render on stderr). PREVIEW by
#             default — nothing is written until --apply, so the skill layer
#             can confirm the candidate list first (preview-before-mutate).
#   --prune   List entries whose path no longer exists or is no longer a git
#             repo. Preview by default; --apply removes them.
#   --suggest-org  gh best-effort: list <org> repos that have no fleet entry
#             (matched on the `repo` slug), as advisory JSON. Never clones —
#             nyann governs existing working copies only. Missing gh / failed
#             auth soft-skips with an empty list.
#
# The registry is pure data — nothing in it is ever executed. Writes are
# atomic (tmp + mv) under a lock, mirroring the watch-list writer.
#
# Requires jq. git required for --add/--scan/--prune validation.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

mode=""
arg=""
name=""
repo_slug=""
profile=""
tags=()
watch=false
depth=2
apply=false
fleet_file="${HOME}/.claude/nyann/fleet.json"
watch_list="${HOME}/.claude/nyann/watch-list.json"

set_mode() {
  [[ -z "$mode" ]] || nyann::die "only one of --add / --remove / --list / --scan / --prune / --suggest-org may be given"
  mode="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)            set_mode add; arg="${2-}"; shift 2 ;;
    --add=*)          set_mode add; arg="${1#--add=}"; shift ;;
    --remove)         set_mode remove; arg="${2-}"; shift 2 ;;
    --remove=*)       set_mode remove; arg="${1#--remove=}"; shift ;;
    --list)           set_mode list; shift ;;
    --scan)           set_mode scan; arg="${2-}"; shift 2 ;;
    --scan=*)         set_mode scan; arg="${1#--scan=}"; shift ;;
    --prune)          set_mode prune; shift ;;
    --suggest-org)    set_mode suggest-org; arg="${2-}"; shift 2 ;;
    --suggest-org=*)  set_mode suggest-org; arg="${1#--suggest-org=}"; shift ;;
    --name)           name="${2-}"; shift 2 ;;
    --name=*)         name="${1#--name=}"; shift ;;
    --repo)           repo_slug="${2-}"; shift 2 ;;
    --repo=*)         repo_slug="${1#--repo=}"; shift ;;
    --profile)        profile="${2-}"; shift 2 ;;
    --profile=*)      profile="${1#--profile=}"; shift ;;
    --tag)            tags+=("${2-}"); shift 2 ;;
    --tag=*)          tags+=("${1#--tag=}"); shift ;;
    --watch)          watch=true; shift ;;
    --depth)          depth="${2-}"; shift 2 ;;
    --depth=*)        depth="${1#--depth=}"; shift ;;
    --apply)          apply=true; shift ;;
    --fleet-file)     fleet_file="${2-}"; shift 2 ;;
    --fleet-file=*)   fleet_file="${1#--fleet-file=}"; shift ;;
    --watch-list)     watch_list="${2-}"; shift 2 ;;
    --watch-list=*)   watch_list="${1#--watch-list=}"; shift ;;
    -h|--help)        sed -n '3,55p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$mode" ]] || nyann::die "one of --add / --remove / --list / --scan / --prune / --suggest-org is required"

# --- Validation helpers -------------------------------------------------------

# valid_entry_name <name> — display names double as --only/--remove keys, so
# keep them to one path-safe token (no slash, no leading dash).
valid_entry_name() {
  local n="${1-}"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$n" != -* ]] || return 1
  case "$n" in .|..) return 1 ;; esac
  return 0
}

# valid_repo_slug <slug> — same shape rule as the sentinel watch-list writer,
# so a --watch mirror can never write a slug the aggregator would reject.
valid_repo_slug() {
  local r="${1-}"
  [[ -n "$r" ]] || return 1
  [[ "$r" != -* ]] || return 1
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  case "$r" in
    .|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
  esac
  return 0
}

# valid_profile_ref <p> — bare profile name or namespaced team/name, matching
# what load-profile.sh resolves.
valid_profile_ref() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  if [[ "$p" == */* ]]; then
    nyann::valid_profile_name "${p%%/*}" && nyann::valid_profile_name "${p#*/}"
  else
    nyann::valid_profile_name "$p"
  fi
}

# resolve_repo_toplevel <path> — canonicalise to the git toplevel so adds at
# different depths dedupe to one entry. Prints the toplevel; returns 1 when
# the path isn't (inside) a git work tree.
resolve_repo_toplevel() {
  local p="${1-}"
  [[ -n "$p" && -d "$p" ]] || return 1
  git -C "$p" rev-parse --show-toplevel 2>/dev/null
}

# slug_from_origin <toplevel> — best-effort <owner>/<repo> from the origin
# remote URL (https://github.com/o/r[.git], git@github.com:o/r[.git],
# ssh://git@github.com/o/r[.git]). Prints nothing when unresolvable.
slug_from_origin() {
  local url slug
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  [[ -n "$url" ]] || return 0
  slug="$url"
  slug="${slug%.git}"
  case "$slug" in
    https://*/*/*)   slug="${slug#https://}"; slug="${slug#*/}" ;;
    ssh://*/*/*)     slug="${slug#ssh://}";   slug="${slug#*/}" ;;
    *@*:*/*)         slug="${slug#*:}" ;;
    *) return 0 ;;
  esac
  if valid_repo_slug "$slug"; then
    printf '%s\n' "$slug"
  fi
  return 0
}

# --- Registry read / write ----------------------------------------------------

read_registry() {
  if [[ -f "$fleet_file" ]]; then
    jq -e 'if type == "array" then . else empty end' "$fleet_file" 2>/dev/null || {
      nyann::warn "fleet registry is not a JSON array — treating as empty: $fleet_file"
      echo "[]"
    }
  else
    echo "[]"
  fi
}

# write_registry <json> — atomically replace the registry under a lock
# (mirrors the watch-list writer).
write_registry() {
  local json="$1"
  local dir; dir="$(dirname "$fleet_file")"
  mkdir -p "$dir" 2>/dev/null || true
  local lock="${fleet_file}.lock"
  local tmp="${fleet_file}.tmp.$$"
  nyann::lock "$lock"
  trap 'rm -f "$tmp"; nyann::unlock "$lock"' EXIT
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$fleet_file"
  nyann::unlock "$lock"
  trap - EXIT
}

# add_one <toplevel> — merge one repo into the registry (create or update).
# Consumes the mode-level $name/$repo_slug/$profile/$tags for the entry
# fields; callers doing batch adds (--scan --apply) reset those first.
add_one() {
  local top="$1"
  local entry_name="${name:-$(basename "$top")}"
  valid_entry_name "$entry_name" \
    || nyann::die "entry name must match [A-Za-z0-9._-]+ (got: $entry_name) — pass --name"
  if [[ -n "$repo_slug" ]]; then
    valid_repo_slug "$repo_slug" || nyann::die "invalid repo (expected <owner>/<repo>): $repo_slug"
  fi
  if [[ -n "$profile" ]]; then
    valid_profile_ref "$profile" || nyann::die "invalid profile name: $profile"
  fi
  local t
  for t in "${tags[@]:-}"; do
    [[ -z "$t" ]] && continue
    valid_entry_name "$t" || nyann::die "invalid tag (want [A-Za-z0-9._-]+): $t"
  done

  local current updated tags_json
  current="$(read_registry)"

  # A name that already belongs to a DIFFERENT path would make --only /
  # --remove-by-name ambiguous — refuse rather than silently shadow.
  local clash
  clash=$(jq -r --arg n "$entry_name" --arg p "$top" \
    '[.[] | select(((.name // (.path | split("/") | last)) == $n) and .path != $p)] | length' <<<"$current")
  if [[ "$clash" != "0" ]]; then
    nyann::die "name '$entry_name' already names a different repo — pass a distinct --name"
  fi

  tags_json="$(printf '%s\n' "${tags[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')"
  updated="$(jq \
    --arg p "$top" --arg n "$entry_name" --arg r "$repo_slug" \
    --arg prof "$profile" --argjson t "$tags_json" '
    if any(.[]?; .path == $p)
    then map(if .path == $p
      then .name = $n
         | (if $r    != "" then .repo    = $r    else . end)
         | (if $prof != "" then .profile = $prof else . end)
         | (if ($t | length) > 0 then .tags = (((.tags // []) + $t) | unique) else . end)
      else . end)
    else . + [
      {path: $p, name: $n}
      + (if $r    != "" then {repo: $r}       else {} end)
      + (if $prof != "" then {profile: $prof} else {} end)
      + (if ($t | length) > 0 then {tags: ($t | unique)} else {} end)
    ] end
  ' <<<"$current")"
  write_registry "$updated"
  nyann::log "fleet: added $entry_name ($top)"

  if $watch; then
    local slug="$repo_slug"
    [[ -z "$slug" ]] && slug="$(slug_from_origin "$top")"
    if [[ -n "$slug" ]]; then
      bash "${_script_dir}/sentinel-aggregate.sh" --add "$slug" --watch-list "$watch_list" \
        || nyann::warn "fleet: watch-list mirror failed for $slug (fleet entry kept)"
      # Persist the resolved slug on the entry so the join key survives.
      current="$(read_registry)"
      updated="$(jq --arg p "$top" --arg r "$slug" \
        'map(if .path == $p then .repo = $r else . end)' <<<"$current")"
      write_registry "$updated"
    else
      nyann::warn "fleet: no <owner>/<repo> slug resolvable for $top — skipped watch-list mirror (pass --repo)"
    fi
  fi
}

# scan_candidates <dir> — print newline-separated toplevels of git repos under
# <dir> (maxdepth $depth directories down) that are NOT yet registered.
scan_candidates() {
  local root="$1" current gitdir top
  current="$(read_registry)"
  # A repo at depth N has its .git marker at depth N+1. `.git` may be a
  # directory (normal clone) or a file (worktree / submodule) — match both.
  find "$root" -mindepth 1 -maxdepth $((depth + 1)) -name .git \( -type d -o -type f \) 2>/dev/null \
    | sort \
    | while IFS= read -r gitdir; do
        top=$(resolve_repo_toplevel "$(dirname "$gitdir")") || continue
        [[ -n "$top" ]] || continue
        if [[ "$(jq -r --arg p "$top" '[.[] | select(.path == $p)] | length' <<<"$current")" == "0" ]]; then
          printf '%s\n' "$top"
        fi
      done | sort -u
}

# --- Modes --------------------------------------------------------------------

case "$mode" in
  add)
    [[ -n "$arg" ]] || nyann::die "--add requires a path"
    top=$(resolve_repo_toplevel "$arg") \
      || nyann::die "not a git repo (or missing): $arg"
    add_one "$top"
    ;;

  remove)
    [[ -n "$arg" ]] || nyann::die "--remove requires a name or path"
    current="$(read_registry)"
    # Only a slash (or explicit ./ ../ /) marks the argument as a path; a
    # bare token is always a NAME even when a same-named directory happens
    # to exist in the cwd — otherwise `--remove api` beside an ./api dir
    # would resolve to a toplevel and remove the wrong entry.
    if [[ "$arg" == */* ]]; then
      top=$(resolve_repo_toplevel "$arg" 2>/dev/null || true)
      [[ -z "$top" ]] && top="$arg"
      updated="$(jq --arg p "$top" 'map(select(.path != $p))' <<<"$current")"
      write_registry "$updated"
      nyann::log "fleet: removed $top"
    else
      matches=$(jq -r --arg n "$arg" \
        '[.[] | select((.name // (.path | split("/") | last)) == $n)] | length' <<<"$current")
      if [[ "$matches" == "0" ]]; then
        nyann::log "fleet: no entry named $arg (no-op)"
      elif [[ "$matches" != "1" ]]; then
        nyann::die "name '$arg' matches $matches entries — remove by path instead"
      else
        updated="$(jq --arg n "$arg" \
          'map(select((.name // (.path | split("/") | last)) != $n))' <<<"$current")"
        write_registry "$updated"
        nyann::log "fleet: removed $arg"
      fi
    fi
    ;;

  list)
    read_registry
    ;;

  scan)
    [[ -n "$arg" && -d "$arg" ]] || nyann::die "--scan requires an existing directory"
    if ! [[ "$depth" =~ ^[0-9]+$ ]] || (( depth < 1 )); then
      nyann::die "--depth must be a positive integer (got: $depth)"
    fi
    candidates=()
    while IFS= read -r c; do
      [[ -n "$c" ]] && candidates+=("$c")
    done < <(scan_candidates "$arg")
    if $apply; then
      if (( ${#candidates[@]} == 0 )); then
        nyann::log "fleet: scan found nothing new under $arg"
      fi
      # Batch add: per-candidate defaults only — the mode-level --name /
      # --repo / --profile flags are single-entry concepts and must not
      # fan out across a batch. Tags DO fan out (that's the natural way
      # to label a scanned group, e.g. --tag work).
      name="" repo_slug="" profile="" watch=false
      for c in "${candidates[@]:-}"; do
        [[ -z "$c" ]] && continue
        add_one "$c"
      done
    else
      {
        if (( ${#candidates[@]} == 0 )); then
          printf 'fleet scan: nothing new under %s (depth %s)\n' "$arg" "$depth"
        else
          printf 'fleet scan: %s unregistered repo(s) under %s (depth %s):\n' "${#candidates[@]}" "$arg" "$depth"
          for c in "${candidates[@]}"; do printf '  + %s\n' "$c"; done
          printf 'Preview only — re-run with --apply to register them.\n'
        fi
      } >&2
    fi
    printf '%s\n' "${candidates[@]:-}" | jq -R . | jq -s 'map(select(. != ""))'
    ;;

  prune)
    current="$(read_registry)"
    dead=()
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if ! resolve_repo_toplevel "$p" >/dev/null 2>&1; then
        dead+=("$p")
      fi
    done < <(jq -r '.[]?.path // empty' <<<"$current")
    if $apply; then
      if (( ${#dead[@]} > 0 )); then
        dead_json="$(printf '%s\n' "${dead[@]}" | jq -R . | jq -s 'map(select(. != ""))')"
        updated="$(jq --argjson d "$dead_json" 'map(select(.path as $p | ($d | index($p)) == null))' <<<"$current")"
        write_registry "$updated"
        nyann::log "fleet: pruned ${#dead[@]} dead entries"
      else
        nyann::log "fleet: nothing to prune"
      fi
    else
      {
        if (( ${#dead[@]} == 0 )); then
          printf 'fleet prune: every entry resolves — nothing to prune\n'
        else
          printf 'fleet prune: %s entries no longer resolve to a git repo:\n' "${#dead[@]}"
          for p in "${dead[@]}"; do printf '  - %s\n' "$p"; done
          printf 'Preview only — re-run with --apply to remove them.\n'
        fi
      } >&2
    fi
    printf '%s\n' "${dead[@]:-}" | jq -R . | jq -s 'map(select(. != ""))'
    ;;

  suggest-org)
    [[ -n "$arg" ]] || nyann::die "--suggest-org requires an org name"
    [[ "$arg" =~ ^[A-Za-z0-9._-]+$ ]] || nyann::die "invalid org name: $arg"
    # gh is best-effort everywhere in nyann: missing CLI or failed auth
    # soft-skips with an empty advisory list, never prompts.
    if ! nyann::has_cmd gh || ! gh auth status >/dev/null 2>&1; then
      nyann::log "gh unavailable or unauthenticated — cannot suggest org repos"
      echo "[]"
      exit 0
    fi
    current="$(read_registry)"
    org_json=$(gh repo list "$arg" --limit 200 --json nameWithOwner --jq '[.[].nameWithOwner]' 2>/dev/null || echo "[]")
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$org_json" || org_json="[]"
    jq --argjson have "$(jq '[.[]?.repo // empty]' <<<"$current")" \
      'map(select(. as $r | ($have | index($r)) == null))' <<<"$org_json"
    ;;
esac
