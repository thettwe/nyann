#!/usr/bin/env bash
# undo.sh — safely undo the most recent git operation on a feature branch.
#
# Usage:
#   undo.sh --target <repo> [--scope last-commit|last-N-commits]
#           [--count N] [--strategy soft|mixed|hard] [--dry-run] [--yes]
#
# Scope semantics:
#   - last-commit (default): undo HEAD~1 (one commit).
#   - last-N-commits:        undo HEAD~N. Requires --count.
#
# Strategy:
#   - soft (default):   keep all changes staged. Safest. Resulting working
#                        tree is identical to before the reset.
#   - mixed:            keep changes in the working tree but unstaged.
#   - hard:             discard all changes. REQUIRES explicit --strategy hard
#                        on the command line to avoid accidents.
#
# Safety:
#   - Refuses on main/master/develop. Undoing history on long-lived branches
#     is a merge-disaster vector.
#   - Refuses when HEAD is a merge commit (undoing a merge is a different
#     operation; use `git revert` or `git reset --keep <merge>^1` manually).
#   - Refuses when the target commit is already pushed to a shared remote
#     (detected via branch's upstream tracking ref) UNLESS --allow-pushed
#     is passed explicitly.
#   - Always emits a JSON preview first. Mutation requires both:
#       --yes  (explicit confirmation)  AND  the absence of --dry-run.
#     Without --yes the script prints the preview and exits 0 with
#     status:"preview", forcing the caller to re-run with --yes after
#     showing the preview to a human. The skill layer is responsible
#     for the human prompt.
#
# Output:
#   {
#     "status":  "undone" | "preview" | "refused",
#     "scope":   "last-commit",
#     "count":   1,
#     "strategy":"soft",
#     "target_sha":    "<pre-undo HEAD>",
#     "new_head":      "<post-undo HEAD>",      // post-mutation only
#     "undone_commits":[ {sha, subject} ],
#     "refused_reason": "..."                    // when status=refused
#   }

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
scope="last-commit"
count=1
strategy="soft"
dry_run=false
allow_pushed=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --scope)           scope="${2:-}"; shift 2 ;;
    --scope=*)         scope="${1#--scope=}"; shift ;;
    --count)           count="${2:-}"; shift 2 ;;
    --count=*)         count="${1#--count=}"; shift ;;
    --strategy)        strategy="${2:-}"; shift 2 ;;
    --strategy=*)      strategy="${1#--strategy=}"; shift ;;
    --dry-run)         dry_run=true; shift ;;
    --yes)             yes=true; shift ;;
    --allow-pushed)    allow_pushed=true; shift ;;
    -h|--help)         sed -n '3,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- validate inputs ---------------------------------------------------------

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

case "$scope" in last-commit|last-N-commits) ;; *) nyann::die "--scope must be last-commit|last-N-commits" ;; esac
case "$strategy" in soft|mixed|hard) ;; *) nyann::die "--strategy must be soft|mixed|hard" ;; esac

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
  nyann::die "--count must be a positive integer"
fi
if [[ "$scope" == "last-commit" ]]; then
  count=1
fi

# --- branch safety -----------------------------------------------------------

emit_refused() {
  jq -n \
    --arg scope "$scope" \
    --arg strategy "$strategy" \
    --argjson count "$count" \
    --arg reason "$1" \
    '{status:"refused", scope:$scope, count:$count, strategy:$strategy, refused_reason:$reason}'
  exit 1
}

head_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo '')"
if [[ -z "$head_branch" ]]; then
  emit_refused "detached HEAD — refusing to undo"
fi
case "$head_branch" in
  main|master|develop) emit_refused "refusing to undo on long-lived branch $head_branch — use git revert instead" ;;
esac

# --- resolve HEAD and target ------------------------------------------------

head_sha=$(git -C "$target" rev-parse HEAD 2>/dev/null || echo "")
[[ -n "$head_sha" ]] || emit_refused "HEAD is not a valid commit"

# Collect the commits that would be undone (HEAD~count..HEAD, newest first).
undone_json='[]'
while IFS=$'\t' read -r sha subject; do
  [[ -z "$sha" ]] && continue
  undone_json=$(jq --arg sha "$sha" --arg subject "$subject" \
    '. + [{sha:$sha, subject:$subject}]' <<<"$undone_json")
done < <(git -C "$target" log -n "$count" --pretty=tformat:'%H%x09%s' 2>/dev/null || true)

if [[ "$(jq 'length' <<<"$undone_json")" -lt "$count" ]]; then
  emit_refused "fewer than $count commits available to undo"
fi

# --- merge-commit refusal ----------------------------------------------------

# A merge commit has >1 parent. Undoing via reset is a common foot-gun.
parent_count=$(git -C "$target" rev-list --parents -n1 HEAD | awk '{print NF-1}')
if (( parent_count > 1 )); then
  emit_refused "HEAD is a merge commit — use 'git revert' manually"
fi

# --- already-pushed detection ------------------------------------------------

upstream_full="$(git -C "$target" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)"
if [[ -n "$upstream_full" && "$upstream_full" != "@{upstream}" && "$allow_pushed" != "true" ]]; then
  # Is the commit we're about to undo reachable from upstream?
  if git -C "$target" merge-base --is-ancestor "$head_sha" "$upstream_full" 2>/dev/null; then
    emit_refused "HEAD is already on $upstream_full — pushed commits should be undone with 'git revert' (override with --allow-pushed)"
  fi
fi

# --- build output JSON -------------------------------------------------------

build_output() {
  # $1 = status, $2 = new_head (optional)
  local status="$1" new_head="${2:-}"
  jq -n \
    --arg status "$status" \
    --arg scope "$scope" \
    --argjson count "$count" \
    --arg strategy "$strategy" \
    --arg target_sha "$head_sha" \
    --arg new_head "$new_head" \
    --argjson undone "$undone_json" \
    '{
      status:$status, scope:$scope, count:$count, strategy:$strategy,
      target_sha:$target_sha,
      new_head: (if $new_head == "" then null else $new_head end),
      undone_commits:$undone
    }'
}

if $dry_run; then
  build_output "preview"
  exit 0
fi

# Preview-before-mutate guard. Without --yes the caller hasn't shown
# the JSON preview to a human and gotten an explicit go-ahead, so we
# refuse to reset and emit the preview instead — letting the caller
# (skill layer) prompt the user and re-invoke with --yes. The header
# docstring promised this; the previous code just forgot to enforce it.
if ! $yes; then
  build_output "preview"
  nyann::warn "preview only: re-run with --yes to apply (or --dry-run to confirm intent)"
  exit 0
fi

# --- execute reset -----------------------------------------------------------

reset_flag="--${strategy}"
reset_err=$(mktemp -t nyann-undo.XXXXXX)
trap 'rm -f "$reset_err"' EXIT
if ! git -C "$target" reset "$reset_flag" "HEAD~${count}" >"$reset_err" 2>&1; then
  err=$(cat "$reset_err")
  nyann::die "git reset failed: $err"
fi

new_sha=$(git -C "$target" rev-parse HEAD)
build_output "undone" "$new_sha"
