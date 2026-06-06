#!/usr/bin/env bash
# ci-gate.sh — gate a release on green CI for HEAD's PR.
#
# Usage:
#   ci-gate.sh --target <repo>
#              [--gh <path>]
#              [--allow-no-pr] [--allow-no-checks]
#              [--timeout <sec>] [--interval <sec>]
#
# Output (JSON on stdout):
#   { "outcome": "pass"|"no-pr-found"|"no-checks", "pr_number": N }
#
# Exit codes:
#   0 — gate passed (or allowed through)
#   2 — gate failed (CI failed, timeout, or refused)

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

target="$PWD"
gh_bin="gh"
allow_no_pr=false
allow_no_checks=false
wait_timeout=1800
wait_interval=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --gh)              gh_bin="${2:-}"; shift 2 ;;
    --gh=*)            gh_bin="${1#--gh=}"; shift ;;
    --allow-no-pr)     allow_no_pr=true; shift ;;
    --allow-no-checks) allow_no_checks=true; shift ;;
    --timeout)         wait_timeout="${2:-}"; shift 2 ;;
    --timeout=*)       wait_timeout="${1#--timeout=}"; shift ;;
    --interval)        wait_interval="${2:-}"; shift 2 ;;
    --interval=*)      wait_interval="${1#--interval=}"; shift ;;
    -h|--help)         sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "ci-gate: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "ci-gate: --target must be a directory"

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  nyann::die "ci-gate: gh binary not found at '$gh_bin' — install gh or skip --wait-for-checks"
fi
if ! "$gh_bin" auth status >/dev/null 2>&1; then
  nyann::die "ci-gate: gh is not authenticated — run 'gh auth login' or skip --wait-for-checks"
fi

head_sha=$(git -C "$target" rev-parse HEAD)
branch=$(git -C "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Resolve the PR by EXACT head SHA, not a free-text search. `gh pr list --search`
# is a full-text query that can match a PR merely mentioning the SHA, or a stale
# closed PR. Match on the branch's open PR whose headRefOid equals HEAD; fall back
# to the commit→PR API which maps a SHA to the PRs it actually heads.
pr_num=""
if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
  pr_list_json=$("$gh_bin" pr list --head "$branch" --state all --limit 10 \
    --json number,headRefOid 2>/dev/null || echo '[]')
  pr_num=$(jq -r --arg sha "$head_sha" \
    'map(select(.headRefOid == $sha)) | .[0].number // empty' <<<"$pr_list_json" 2>/dev/null || true)
fi

if [[ -z "$pr_num" ]]; then
  # Detached HEAD, or no branch PR matched: ask GitHub which PRs this commit heads.
  api_json=$("$gh_bin" api "repos/{owner}/{repo}/commits/${head_sha}/pulls" 2>/dev/null || echo '[]')
  pr_num=$(jq -r --arg sha "$head_sha" \
    'map(select(.head.sha == $sha)) | .[0].number // empty' <<<"$api_json" 2>/dev/null || true)
fi

if [[ -z "$pr_num" ]]; then
  if $allow_no_pr; then
    nyann::warn "ci-gate: no PR found for HEAD ($head_sha); proceeding because --allow-no-pr was set"
    jq -n '{outcome:"no-pr-found"}'
    exit 0
  else
    nyann::die "ci-gate: no PR found for HEAD ($head_sha); refusing to proceed without a verified CI signal. Re-run with --allow-no-pr to release anyway."
  fi
fi

nyann::log "ci-gate: polling PR #$pr_num CI (timeout=${wait_timeout}s, interval=${wait_interval}s)..."
checks_out=$("${_script_dir}/../wait-for-pr-checks.sh" --target "$target" \
  --pr "$pr_num" --gh "$gh_bin" --timeout "$wait_timeout" --interval "$wait_interval") || true
checks_outcome=$(jq -r '.outcome // "skipped"' <<<"$checks_out" 2>/dev/null || echo "skipped")

case "$checks_outcome" in
  pass)
    nyann::log "ci-gate: PR #$pr_num CI passed"
    jq -n --arg outcome "pass" --argjson pr "$pr_num" '{outcome:$outcome, pr_number:$pr}'
    ;;
  no-checks)
    if $allow_no_checks; then
      nyann::warn "ci-gate: no checks attached to PR #$pr_num — proceeding because --allow-no-checks was set"
      jq -n --argjson pr "$pr_num" '{outcome:"no-checks", pr_number:$pr}'
    else
      nyann::die "ci-gate: no checks attached to PR #$pr_num — re-run with --allow-no-checks if the repo genuinely has no PR CI."
    fi
    ;;
  fail)
    nyann::die "ci-gate: PR #$pr_num CI failed; inspect via 'gh pr checks $pr_num'"
    ;;
  timeout)
    nyann::die "ci-gate: PR #$pr_num CI did not settle within ${wait_timeout}s; rerun with --wait-for-checks-timeout=<larger>"
    ;;
  *)
    nyann::die "ci-gate: could not poll PR #$pr_num CI (outcome=${checks_outcome})"
    ;;
esac
