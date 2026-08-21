#!/usr/bin/env bash
# github-issues.sh — deliver a batch of Notification entries as a comment on
# a per-repo "nyann sentinel digest" GitHub issue.
#
# Usage:
#   github-issues.sh --repo <owner/repo> [--labels <csv>] [--title <t>]
#                    < notifications.json
#
# DIGEST MODEL, not issue-per-notification: one open issue (matched by exact
# TITLE — the stable key; labels are applied best-effort and may not exist in
# the target repo) collects one comment per delivered batch. This keeps a
# flapping check from polluting the team's issue tracker with N issues; the
# orchestrator's per-channel dedup already keeps batches from repeating.
#
# gh is best-effort per the standing convention: missing gh or failed auth
# soft-skips (75), never prompts for credentials. No secrets are handled here
# at all — gh's own auth carries the API access.
#
# INJECTION: notification messages are attacker-influenceable (PR titles,
# branch names). Each message is stripped of CR/LF and backticks and wrapped
# in a markdown code span, so it can neither break the list structure nor
# ping @mentions nor smuggle markdown into the digest.
#
# EXIT CONTRACT (shared with notify-deliver.sh): exit 0 ONLY on a confirmed
# comment post. Soft-skips (no gh / no auth / invalid repo) return 75; an API
# failure returns gh's status — either way the orchestrator leaves the batch
# UN-marked for this channel and retries it next poll.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

repo=""
labels=""
title="nyann sentinel digest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     repo="${2-}"; shift 2 ;;
    --repo=*)   repo="${1#--repo=}"; shift ;;
    --labels)   labels="${2-}"; shift 2 ;;
    --labels=*) labels="${1#--labels=}"; shift ;;
    --title)    title="${2-}"; shift 2 ;;
    --title=*)  title="${1#--title=}"; shift ;;
    -h|--help)  sed -n '3,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# Validate the target slug BEFORE it reaches gh's argv (option-injection /
# traversal guard, mirroring the watch-list writer). Invalid → soft-skip.
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
if ! valid_repo_slug "$repo"; then
  nyann::warn "github-issues: invalid repo slug '${repo:-<empty>}' — skipping"
  exit 75
fi

if ! nyann::has_cmd gh; then
  nyann::warn "github-issues: gh CLI not installed — skipping delivery"
  exit 75
fi
if ! gh auth status >/dev/null 2>&1; then
  nyann::warn "github-issues: gh is not authenticated — skipping delivery"
  exit 75
fi

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# --- Find (or create once) the digest issue ----------------------------------
# The exact title is the stable key: a label may not exist in the target repo
# (creating with a missing label FAILS), so labels are best-effort decoration.
issue_number=$(gh issue list --repo "$repo" --state open \
  --search "\"$title\" in:title" --json number,title 2>/dev/null \
  | jq -r --arg t "$title" 'first(.[] | select(.title == $t)) | .number // empty' 2>/dev/null || true)

if [[ -z "$issue_number" ]]; then
  create_args=(--repo "$repo" --title "$title"
               --body "Automated digest of nyann CI-sentinel notifications for this repo. Each delivery batch lands as a comment below. Managed by the nyann \`github_issues\` delivery channel — disable it in /nyann:settings to stop these.")
  if [[ -n "$labels" ]]; then
    local_labels_args=()
    IFS=',' read -r -a _label_arr <<<"$labels"
    for _l in "${_label_arr[@]}"; do
      [[ -n "$_l" ]] && local_labels_args+=(--label "$_l")
    done
    if ! issue_url=$(gh issue create "${create_args[@]}" "${local_labels_args[@]}" 2>/dev/null); then
      # The label(s) may not exist in the repo — retry unlabeled rather than
      # failing delivery over decoration.
      nyann::warn "github-issues: create with labels failed (missing label?) — retrying without labels"
      issue_url=$(gh issue create "${create_args[@]}" 2>/dev/null) || {
        nyann::warn "github-issues: could not create the digest issue in $repo"
        exit 1
      }
    fi
  else
    issue_url=$(gh issue create "${create_args[@]}" 2>/dev/null) || {
      nyann::warn "github-issues: could not create the digest issue in $repo"
      exit 1
    }
  fi
  issue_number="${issue_url##*/}"
fi

if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
  nyann::warn "github-issues: could not resolve a digest issue number in $repo"
  exit 1
fi

# --- Compose + post the batch comment ----------------------------------------
# Messages are wrapped in code spans with CR/LF and backticks stripped —
# structure-safe and @mention-inert.
body=$(jq -r --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
  def clean: tostring | gsub("[\r\n`]"; " ");
  "### nyann sentinel — " + $ts + "\n\n"
  + ([.[] |
      "- **[" + (.severity // "info" | clean) + "]** "
      + (if .context.repo then "[" + (.context.repo | clean) + "] " else "" end)
      + "`" + (.message // "" | clean) + "`"
      + (if .context.pr then " (PR #\(.context.pr))" else "" end)
     ] | join("\n"))' <<<"$batch")

rc=0
printf '%s\n' "$body" \
  | gh issue comment "$issue_number" --repo "$repo" --body-file - >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then
  nyann::warn "github-issues: failed to comment on issue #$issue_number in $repo"
fi
exit "$rc"
