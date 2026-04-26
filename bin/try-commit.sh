#!/usr/bin/env bash
# try-commit.sh — attempt `git commit` and return a structured result.
#
# Usage:
#   try-commit.sh --target <repo> --subject <subject> [--body <body>]
#
# Always exits 0; the caller reads the JSON on stdout to decide what to do.
# Structured so the `commit` skill can programmatically decide whether to
# regenerate the message vs. give up after the 2-retry cap.
#
# Output shape:
#   {
#     "result":   "committed" | "rejected" | "error",
#     "sha":      "<sha>" | null,
#     "subject":  "<the subject line we tried>",
#     "stage":    "commit-msg" | "pre-commit" | "pre-push" | "other" | null,
#     "reason":   "<stderr from the hook, trimmed>" | null,
#     "exit_code": N
#   }

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
subject=""
body=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2:-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --subject)   subject="${2:-}"; shift 2 ;;
    --subject=*) subject="${1#--subject=}"; shift ;;
    --body)      body="${2:-}"; shift 2 ;;
    --body=*)    body="${1#--body=}"; shift ;;
    -h|--help)   sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$subject" ]] || nyann::die "--subject is required"
[[ "$subject" != -* ]] || nyann::die "--subject must not start with '-'"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

tmperr=$(mktemp -t nyann-commit-err.XXXXXX)
trap 'rm -f "$tmperr"' EXIT

set +e
if [[ -n "$body" ]]; then
  git -C "$target" commit -m "$subject" -m "$body" > /dev/null 2> "$tmperr"
else
  git -C "$target" commit -m "$subject" > /dev/null 2> "$tmperr"
fi
rc=$?
set -e

# Classify the outcome.
result="error"
stage="null"
reason="null"
sha=""

if (( rc == 0 )); then
  result="committed"
  sha=$(git -C "$target" rev-parse HEAD 2>/dev/null || echo "")
else
  err=$(cat "$tmperr")
  # Trim long tracebacks.
  reason_plain="${err:0:2000}"
  if grep -qE '\.git/hooks/commit-msg|hint:\s*The commit-msg hook|Conventional Commits' <<<"$err"; then
    result="rejected"; stage='"commit-msg"'
  elif grep -qE '\.git/hooks/pre-commit|block-main|gitleaks' <<<"$err"; then
    result="rejected"; stage='"pre-commit"'
  elif grep -qE '\.git/hooks/pre-push' <<<"$err"; then
    result="rejected"; stage='"pre-push"'
  fi
  reason=$(jq -Rn --arg r "$reason_plain" '$r')
fi

rm -f "$tmperr"

if [[ "$result" == "rejected" ]]; then
  jq -n --arg subject "$subject" --argjson stage "$stage" --argjson reason "$reason" --argjson rc "$rc" \
    '{ result: "rejected", sha: null, subject: $subject, stage: $stage, reason: $reason, exit_code: $rc }'
elif [[ "$result" == "committed" ]]; then
  jq -n --arg subject "$subject" --arg sha "$sha" \
    '{ result: "committed", sha: (if $sha == "" then null else $sha end), subject: $subject, stage: null, reason: null, exit_code: 0 }'
else
  jq -n --arg subject "$subject" --argjson reason "$reason" --argjson rc "$rc" \
    '{ result: "error", sha: null, subject: $subject, stage: null, reason: $reason, exit_code: $rc }'
fi
