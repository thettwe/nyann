#!/usr/bin/env bash
# pr.sh — open a GitHub PR from the current branch with best-effort context.
#
# Usage:
#   pr.sh --target <repo> [--base <branch>] [--title <str>] [--body <str>]
#         [--draft] [--context-only] [--gh <path>]
#
# Modes:
#   default         → push current branch + invoke `gh pr create`
#   --context-only  → gather context only; print JSON. No network calls,
#                     and the gh auth check is also skipped (the script
#                     exits with the summary before reaching the gh
#                     guard), so this mode works even when gh is
#                     missing or unauthenticated. Use it from the skill
#                     layer when you want the LLM to synthesize title
#                     and body before shipping.
#   --auto-merge    → after creating the PR, run `gh pr merge --auto`
#                     with strategy from .github.auto_merge_strategy
#                     (squash | rebase | merge, default squash). GitHub's
#                     auto-merge feature waits server-side for required
#                     status checks + reviews; this script returns
#                     immediately. The output JSON adds an `auto_merge`
#                     field reporting setup outcome.
#
# Output (context JSON shape):
#   {
#     "head":          "feat/foo",
#     "base":          "main",
#     "commits":       [{ "sha": "...", "subject": "..." }],
#     "ahead":         3,
#     "behind":        0,
#     "has_remote":    true,
#     "remote_url":    "...",
#     "suggested_title": "feat: ..."  // most recent commit subject
#   }
#
# Success path emits one of:
#   { "url": "https://github.com/..." }                 — PR created
#   { "skipped": "...", "reason": "..." }               — gh missing/auth/etc
#   exits 2 on hard errors (not a git repo, no branch).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
base=""
title=""
body=""
draft=false
context_only=false
auto_merge=false
auto_merge_strategy="squash"
profile_name=""
user_root=""
gh_bin="gh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)             target="${2:-}"; shift 2 ;;
    --target=*)           target="${1#--target=}"; shift ;;
    --base)               base="${2:-}"; shift 2 ;;
    --base=*)             base="${1#--base=}"; shift ;;
    --title)              title="${2:-}"; shift 2 ;;
    --title=*)            title="${1#--title=}"; shift ;;
    --body)               body="${2:-}"; shift 2 ;;
    --body=*)             body="${1#--body=}"; shift ;;
    --draft)              draft=true; shift ;;
    --context-only)       context_only=true; shift ;;
    --auto-merge)         auto_merge=true; shift ;;
    --auto-merge-strategy) auto_merge_strategy="${2:-squash}"; shift 2 ;;
    --auto-merge-strategy=*) auto_merge_strategy="${1#--auto-merge-strategy=}"; shift ;;
    --profile)            profile_name="${2:-}"; shift 2 ;;
    --profile=*)          profile_name="${1#--profile=}"; shift ;;
    --user-root)          user_root="${2:-}"; shift 2 ;;
    --user-root=*)        user_root="${1#--user-root=}"; shift ;;
    --gh)                 gh_bin="${2:-}"; shift 2 ;;
    --gh=*)               gh_bin="${1#--gh=}"; shift ;;
    -h|--help)            sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

case "$auto_merge_strategy" in
  squash|rebase|merge) ;;
  *) nyann::die "--auto-merge-strategy must be one of: squash, rebase, merge" ;;
esac

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || { nyann::warn "$target is not a git repo"; exit 2; }

skip() {
  jq -n --arg reason "$1" '{skipped:"pr", reason:$reason}'
  exit 0
}

# --- branch checks -----------------------------------------------------------

head_branch="$(git -C "$target" branch --show-current 2>/dev/null || echo '')"
[[ -n "$head_branch" ]] || { nyann::warn "detached HEAD; cannot open PR"; exit 2; }

case "$head_branch" in
  main|master) nyann::warn "cannot open PR from $head_branch"; exit 2 ;;
esac

# Resolve base: arg > upstream tracking ref > origin/HEAD > "main".
if [[ -n "$base" ]] && ! nyann::valid_git_ref "$base"; then
  nyann::die "--base must be a valid git ref: got '$base'"
fi
if [[ -z "$base" ]]; then
  upstream_full="$(git -C "$target" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)"
  if [[ -n "$upstream_full" && "$upstream_full" != "@{upstream}" ]]; then
    # origin/main → main
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

# Defence-in-depth: the upstream/HEAD strips above can produce a value
# starting with `-` (attacker-controlled `.git/config` with
# `branch.<>.merge = refs/heads/--exec=evil`). git rev-parse --verify
# below would reject that ref, but applying the helper here keeps the
# guard consistent with --base.
if ! nyann::valid_git_ref "$base"; then
  nyann::warn "resolved base '$base' is not a valid git ref"
  exit 2
fi

# --- commit range vs base ----------------------------------------------------

commits_json='[]'
ahead=0
behind=0
if git -C "$target" rev-parse --verify "$base" >/dev/null 2>&1; then
  # Collect commit subjects head..base (not base..head — we want head's unique commits).
  while IFS=$'\t' read -r sha subject; do
    [[ -z "$sha" ]] && continue
    commits_json=$(jq --arg sha "$sha" --arg subject "$subject" \
      '. + [{sha:$sha, subject:$subject}]' <<<"$commits_json")
  done < <(git -C "$target" log --pretty=tformat:'%H%x09%s' "${base}..${head_branch}" 2>/dev/null || true)

  read -r ahead behind < <(git -C "$target" rev-list --left-right --count "${head_branch}...${base}" 2>/dev/null || echo "0 0")
fi

# Suggested title: most recent commit subject on the head branch.
suggested_title="$(jq -r '.[0].subject // ""' <<<"$commits_json")"

# --- remote info -------------------------------------------------------------

remote_url="$(git -C "$target" remote get-url origin 2>/dev/null || echo '')"
has_remote=false
[[ -n "$remote_url" ]] && has_remote=true

# Redact embedded credentials before the URL lands in our JSON context
# output. `https://<token>@host/...` is a common pattern for PAT-based
# auth; leaking it into a log file or skill-layer message would expose
# the token.
remote_url_safe=$(nyann::redact_url "$remote_url")

# --- context-only mode: emit JSON + exit 0 -----------------------------------

emit_context() {
  jq -n \
    --arg head "$head_branch" \
    --arg base "$base" \
    --argjson commits "$commits_json" \
    --argjson ahead "${ahead:-0}" \
    --argjson behind "${behind:-0}" \
    --argjson has_remote "$has_remote" \
    --arg remote_url "$remote_url_safe" \
    --arg suggested_title "$suggested_title" \
    '{
      head: $head, base: $base,
      commits: $commits, ahead: $ahead, behind: $behind,
      has_remote: $has_remote, remote_url: $remote_url,
      suggested_title: $suggested_title
    }'
}

if $context_only; then
  emit_context
  exit 0
fi

# --- gh guard (create path only) --------------------------------------------

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  nyann::warn "gh not found on PATH; cannot open PR"
  skip "gh-not-installed"
fi
if ! "$gh_bin" auth status >/dev/null 2>&1; then
  nyann::warn "gh is installed but not authenticated; cannot open PR"
  skip "gh-not-authenticated"
fi
$has_remote || skip "no-origin-remote"

# --- sanity checks on title / body ------------------------------------------

[[ -n "$title" ]] || nyann::die "--title is required unless --context-only"
[[ ${#commits_json} -gt 4 ]] || nyann::die "head branch has no commits ahead of $base"

# --- push then create --------------------------------------------------------
# Push with -u so tracking is set; idempotent if already up-to-date.
# Defensive git config: pin protocol allowlist + neutralise core.hooksPath
# so a malicious origin URL inserted into .git/config can't trigger an
# `ext::` transport command or a pre-push hook checked into the repo.
# Symmetric with the team-source git operations.
git_safe_push=(-c protocol.allow=user -c protocol.ext.allow=never \
               -c protocol.file.allow=user \
               -c core.hooksPath=/dev/null)

push_err=$(mktemp -t nyann-pr-push.XXXXXX)
trap 'rm -f "$push_err"' EXIT
if ! git "${git_safe_push[@]}" -C "$target" push -u origin "$head_branch" >"$push_err" 2>&1; then
  # Git push errors can include the remote URL (with tokens). Redact
  # before surfacing.
  err=$(nyann::redact_url "$(cat "$push_err")")
  nyann::die "git push failed: $err"
fi

gh_args=(pr create --base "$base" --head "$head_branch" --title "$title")
# Only attach --body when non-empty so gh can apply repo-default PR
# template / open editor instead of forcing a literal blank body.
if [[ -n "$body" ]]; then
  gh_args+=(--body "$body")
fi
$draft && gh_args+=(--draft)

create_err=$(mktemp -t nyann-pr-create.XXXXXX)
am_err=$(mktemp -t nyann-pr-am.XXXXXX)
trap 'rm -f "$push_err" "$create_err" "$am_err"' EXIT
if ! url="$( ( cd "$target" && "$gh_bin" "${gh_args[@]}" ) 2>"$create_err")"; then
  err="$(cat "$create_err")"
  nyann::die "gh pr create failed: $err"
fi

# --- auto-merge (optional) -------------------------------------------------
# When --auto-merge is set, ask GitHub to auto-merge the PR once the
# required status checks + reviews pass. This is the server-side
# auto-merge feature; the script returns immediately rather than
# polling. Strategy precedence: explicit --auto-merge-strategy >
# .github.auto_merge_strategy from --profile > default "squash".
auto_merge_outcome=""
auto_merge_reason=""
if $auto_merge; then
  # If --profile was passed, let it override the default strategy
  # (CLI explicit --auto-merge-strategy already changed the variable
  # before this point if it was passed).
  if [[ -n "$profile_name" ]] && [[ "$auto_merge_strategy" == "squash" ]]; then
    user_root="${user_root:-${HOME}/.claude/nyann}"
    if profile_strategy=$("${_script_dir}/load-profile.sh" "$profile_name" --user-root "$user_root" 2>/dev/null \
        | jq -r '.github.auto_merge_strategy // empty' 2>/dev/null); then
      [[ -n "$profile_strategy" ]] && auto_merge_strategy="$profile_strategy"
    fi
  fi

  am_args=(pr merge "$url" --auto)
  case "$auto_merge_strategy" in
    squash) am_args+=(--squash) ;;
    rebase) am_args+=(--rebase) ;;
    merge)  am_args+=(--merge) ;;
  esac

  if ( cd "$target" && "$gh_bin" "${am_args[@]}" ) >/dev/null 2>"$am_err"; then
    auto_merge_outcome="enabled"
  else
    # Auto-merge can fail for legitimate reasons that don't make the
    # PR creation itself wrong (e.g. the repo doesn't allow auto-merge,
    # or the PR is already mergeable). Cap stderr and emit as a soft
    # failure inside the JSON; don't kill the script.
    auto_merge_outcome="failed"
    auto_merge_reason=$(head -c 500 "$am_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  fi
fi

if $auto_merge; then
  # Build the auto_merge sub-object first then conditionally add `reason`.
  am_obj=$(jq -n --arg strategy "$auto_merge_strategy" --arg outcome "$auto_merge_outcome" \
    '{strategy:$strategy, outcome:$outcome}')
  if [[ -n "$auto_merge_reason" ]]; then
    am_obj=$(jq --arg reason "$auto_merge_reason" '. + {reason:$reason}' <<<"$am_obj")
  fi
  jq -n --arg url "$url" --argjson am "$am_obj" '{url:$url, auto_merge:$am}'
else
  jq -n --arg url "$url" '{url:$url}'
fi
