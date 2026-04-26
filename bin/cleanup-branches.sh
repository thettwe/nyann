#!/usr/bin/env bash
# cleanup-branches.sh — prune local branches whose tip is reachable
# from the base branch (i.e. the work is already integrated).
#
# Usage:
#   cleanup-branches.sh --target <repo> [--base <branch>] [--dry-run] [--yes]
#
# Modes (mirror the undo / switch-profile contract — preview-then-mutate):
#   default    print the candidate list + warn "re-run with --yes". No
#              deletions. Exits 0.
#   --dry-run  same JSON shape but mode:"dry-run". No deletions.
#   --yes      execute `git branch -d` per candidate. Mode:"applied".
#
# Wraps `bin/check-stale-branches.sh` to find merged_into_base[];
# `git branch -d` (lowercase d) refuses to delete branches that
# aren't reachable from HEAD or upstream, so the apply path cannot
# accidentally drop unmerged work even on race conditions.
#
# Output: CleanupBranchesResult JSON (see
# schemas/cleanup-branches-result.schema.json) on stdout.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
base_branch=""
dry_run=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2:-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --base)     base_branch="${2:-}"; shift 2 ;;
    --base=*)   base_branch="${1#--base=}"; shift ;;
    --dry-run)  dry_run=true; shift ;;
    --yes)      yes=true; shift ;;
    -h|--help)  sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" && -d "$target/.git" ]] || nyann::die "$target is not a git repo"
target="$(cd "$target" && pwd)"

# Reuse the stale-branch detector; it already does base resolution
# and current-branch exclusion.
stale_args=(--target "$target")
[[ -n "$base_branch" ]] && stale_args+=(--base "$base_branch")
report=$("${_script_dir}/check-stale-branches.sh" "${stale_args[@]}") \
  || nyann::die "check-stale-branches.sh failed"

resolved_base=$(jq -r '.base_branch' <<<"$report")
candidates=$(jq -c '.merged_into_base' <<<"$report")
candidate_count=$(jq 'length' <<<"$candidates")

# Determine output mode from the flag triplet.
if $yes && ! $dry_run; then
  mode="applied"
elif $dry_run; then
  mode="dry-run"
else
  mode="preview"
fi

deleted_json='[]'
errors_json='[]'

if [[ "$mode" == "applied" ]] && (( candidate_count > 0 )); then
  # Re-resolve the base SHA so we can re-verify ancestry inline before
  # each delete. `git branch -d` only checks against HEAD/upstream, so
  # if the user runs cleanup from a feature branch, candidates merged
  # into the resolved base would fail the safety check even though
  # they're genuinely safe. We verify ourselves against $resolved_base
  # then use `git branch -D` (force) — safe because we've already
  # confirmed the merge state up-to-the-second.
  base_sha=$(git -C "$target" rev-parse --verify --quiet "refs/heads/${resolved_base}" 2>/dev/null || echo "")
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    name=$(jq -r '.name' <<<"$row")
    sha=$(jq -r '.last_commit_sha' <<<"$row")

    # Inline ancestry re-check. Catches the race where someone added
    # a commit on this branch between check-stale-branches' read and
    # this delete — in that case the branch is no longer fully merged
    # and we MUST refuse, not force.
    branch_sha=$(git -C "$target" rev-parse --verify --quiet "refs/heads/${name}" 2>/dev/null || echo "")
    if [[ -z "$base_sha" ]] || [[ -z "$branch_sha" ]] \
       || ! git -C "$target" merge-base --is-ancestor "$branch_sha" "$base_sha" 2>/dev/null; then
      errors_json=$(jq --arg n "$name" --arg r "branch is not an ancestor of $resolved_base — refusing to force-delete" \
        '. + [{name:$n, reason:$r}]' <<<"$errors_json")
      continue
    fi

    # Force-delete. Safe because we just verified the merge state. The
    # earlier `git branch -d` form was unreliable when the user wasn't
    # checked out on $resolved_base (-d compares against HEAD/upstream).
    if del_err=$(git -C "$target" branch -D -- "$name" 2>&1); then
      deleted_json=$(jq --arg n "$name" --arg s "$sha" \
        '. + [{name:$n, deleted_sha:$s}]' <<<"$deleted_json")
    else
      # Cap stderr at 500 bytes — defence against pathological output.
      reason=$(printf '%s' "$del_err" | head -c 500 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
      errors_json=$(jq --arg n "$name" --arg r "$reason" \
        '. + [{name:$n, reason:$r}]' <<<"$errors_json")
    fi
  done < <(jq -c '.[]' <<<"$candidates")
fi

deleted_count=$(jq 'length' <<<"$deleted_json")
error_count=$(jq 'length' <<<"$errors_json")

jq -n \
  --arg target "$target" \
  --arg base "$resolved_base" \
  --arg mode "$mode" \
  --argjson candidates "$candidates" \
  --argjson deleted "$deleted_json" \
  --argjson errors "$errors_json" \
  --argjson cc "$candidate_count" \
  --argjson dc "$deleted_count" \
  --argjson ec "$error_count" \
  '{
    target: $target,
    base_branch: $base,
    mode: $mode,
    candidates: $candidates,
    deleted: $deleted,
    errors: $errors,
    summary: { candidates_count: $cc, deleted_count: $dc, error_count: $ec }
  }'

# Preview-mode hint to stderr — same UX shape as undo / switch-profile.
if [[ "$mode" == "preview" ]] && (( candidate_count > 0 )); then
  nyann::warn "preview only: re-run with --yes to delete ${candidate_count} merged branch(es) (or --dry-run to confirm intent)"
fi
