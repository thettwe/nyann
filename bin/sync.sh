#!/usr/bin/env bash
# sync.sh — update the current branch against its base (main/master/develop).
#
# Usage:
#   sync.sh --target <repo> [--base <branch>] [--strategy rebase|merge]
#           [--dry-run]
#
# Behavior:
#   1. Refuse if current branch is main/master/develop or a detached HEAD.
#   2. Fetch origin quietly (soft-skip if no remote).
#   3. Check current branch cleanliness — refuse when uncommitted changes
#      exist (caller should commit or stash first).
#   4. Resolve base: --base > @{upstream} > origin/HEAD > "main".
#   5. Run the chosen strategy (default: rebase). Merge is offered for repos
#      that forbid rebase (shared long-lived branches).
#   6. Report result as JSON:
#        { "status": "up-to-date" | "synced" | "conflicts" | "dirty" | "skipped",
#          "strategy": "rebase|merge", "base": "main", "ahead": N, "behind": N,
#          "conflicts": [ "path/a", "path/b" ] }
#
# On conflicts the script stops and leaves the working tree as-is so the user
# (or the skill layer) can decide how to resolve.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
base=""
strategy="rebase"
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2:-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --base)       base="${2:-}"; shift 2 ;;
    --base=*)     base="${1#--base=}"; shift ;;
    --strategy)   strategy="${2:-}"; shift 2 ;;
    --strategy=*) strategy="${1#--strategy=}"; shift ;;
    --dry-run)    dry_run=true; shift ;;
    -h|--help)    sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

case "$strategy" in rebase|merge) ;; *) nyann::die "--strategy must be rebase or merge" ;; esac

if [[ -n "$base" ]] && ! nyann::valid_git_ref "$base"; then
  nyann::die "--base must be a valid git ref: got '$base'"
fi

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || { nyann::warn "$target is not a git repo"; exit 2; }

emit() {
  # $1=status, rest=key=value pairs (string-typed)
  local status="$1"; shift
  jq -n \
    --arg status "$status" \
    --arg strategy "$strategy" \
    --arg base "$base" \
    --arg head "$head_branch" \
    --argjson ahead "${ahead:-0}" \
    --argjson behind "${behind:-0}" \
    --argjson conflicts "${conflicts_json:-[]}" \
    '{status:$status, strategy:$strategy, base:$base, head:$head,
      ahead:$ahead, behind:$behind, conflicts:$conflicts}'
}

# --- branch checks -----------------------------------------------------------

head_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo '')"
[[ -n "$head_branch" ]] || { nyann::warn "detached HEAD; cannot sync"; exit 2; }

case "$head_branch" in
  main|master|develop) nyann::warn "refusing to sync $head_branch (long-lived branch)"; exit 2 ;;
esac

# --- clean working tree ------------------------------------------------------

if ! git -C "$target" diff --quiet || ! git -C "$target" diff --cached --quiet; then
  conflicts_json='[]'
  ahead=0; behind=0
  emit "dirty"
  exit 1
fi

# --- fetch origin ------------------------------------------------------------
# Capture stderr to a redacted error buffer rather than discarding it,
# so the user sees the actual failure cause (auth, blocked transport,
# partial-clone limit) instead of a generic "fetch failed" line.
# Embedded URL credentials are scrubbed via nyann::redact_url so a
# tokened origin doesn't leak into the warn message.

if git -C "$target" remote get-url origin >/dev/null 2>&1; then
  if ! $dry_run; then
    fetch_err=$(mktemp -t nyann-sync-fetch.XXXXXX)
    if ! git -C "$target" fetch --quiet origin 2>"$fetch_err"; then
      err=$(nyann::redact_url "$(head -c 500 "$fetch_err" | tr '\n' ' ')")
      nyann::warn "git fetch origin failed (continuing): $err"
    fi
    rm -f "$fetch_err"
  fi
fi

# --- resolve base ------------------------------------------------------------

if [[ -z "$base" ]]; then
  upstream_full="$(git -C "$target" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)"
  if [[ -n "$upstream_full" && "$upstream_full" != "@{upstream}" ]]; then
    base="${upstream_full#*/}"
  fi
fi
if [[ -z "$base" ]]; then
  if git -C "$target" symbolic-ref refs/remotes/origin/HEAD >/dev/null 2>&1; then
    base="$(git -C "$target" symbolic-ref --short refs/remotes/origin/HEAD)"
    base="${base#origin/}"
  else
    base="main"
  fi
fi

# Re-validate the resolved base. The `${upstream_full#*/}` and
# `${base#origin/}` strips above can produce values starting with `-`
# (an attacker-controlled `.git/config` `branch.<>.merge = refs/heads/--exec=evil`
# slips past the upstream lookup). git rev-parse --verify below
# already rejects most malformed refs, but applying the helper here
# closes the option-injection class uniformly and matches the
# write-path guard in --base.
if ! nyann::valid_git_ref "$base"; then
  conflicts_json='[]'
  ahead=0; behind=0
  nyann::warn "resolved base '$base' is not a valid git ref"
  emit "skipped"
  exit 2
fi

# Prefer the remote-tracking ref if it exists; falls back to the local base
# when origin is missing. This is the ref we rebase/merge onto.
base_ref="$base"
if git -C "$target" rev-parse --verify "refs/remotes/origin/$base" >/dev/null 2>&1; then
  base_ref="origin/$base"
elif ! git -C "$target" rev-parse --verify "$base" >/dev/null 2>&1; then
  conflicts_json='[]'
  ahead=0; behind=0
  nyann::warn "base branch '$base' not found locally or on origin"
  emit "skipped"
  exit 2
fi

# --- ahead/behind ------------------------------------------------------------

read -r ahead behind < <(git -C "$target" rev-list --left-right --count "${head_branch}...${base_ref}" 2>/dev/null || echo "0 0")
conflicts_json='[]'

if (( behind == 0 )); then
  emit "up-to-date"
  exit 0
fi

if $dry_run; then
  emit "synced"   # pretend; dry run doesn't mutate
  exit 0
fi

# --- apply strategy ----------------------------------------------------------
# On conflict: rebase leaves the working tree in a rebase state; the caller
# can `git rebase --continue` or `--abort` manually. Merge leaves an unresolved
# merge commit staged.

sync_err=$(mktemp -t nyann-sync.XXXXXX)
trap 'rm -f "$sync_err"' EXIT

nyann::resolve_identity "$target"

if [[ "$strategy" == "rebase" ]]; then
  if ! git -C "$target" -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
         rebase -- "$base_ref" >"$sync_err" 2>&1; then
    # Collect unmerged paths.
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      conflicts_json=$(jq --arg p "$p" '. + [$p]' <<<"$conflicts_json")
    done < <(git -C "$target" diff --name-only --diff-filter=U 2>/dev/null || true)
    emit "conflicts"
    exit 3
  fi
else
  if ! git -C "$target" -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
         merge --no-edit -- "$base_ref" >"$sync_err" 2>&1; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      conflicts_json=$(jq --arg p "$p" '. + [$p]' <<<"$conflicts_json")
    done < <(git -C "$target" diff --name-only --diff-filter=U 2>/dev/null || true)
    emit "conflicts"
    exit 3
  fi
fi

# Recompute ahead/behind after the operation.
read -r ahead behind < <(git -C "$target" rev-list --left-right --count "${head_branch}...${base_ref}" 2>/dev/null || echo "0 0")
emit "synced"
