#!/usr/bin/env bash
# ship.sh — combine PR creation + check-wait + merge in one invocation.
#
# Usage:
#   ship.sh --target <repo> --title <str> [--body <str>] [--base <branch>]
#           [--client-side] [--merge-strategy squash|rebase|merge]
#           [--profile <name>] [--user-root <path>]
#           [--timeout <sec>] [--interval <sec>]
#           [--gh <path>] [--draft] [--allow-no-checks]
#
# Modes (decided at invocation):
#   default (server-side)  → calls pr.sh --auto-merge under the hood.
#                             GitHub merges when required checks +
#                             reviews pass. ship.sh returns immediately
#                             with outcome:"queued" once auto-merge is
#                             enabled (or "merge-failed" if the repo
#                             doesn't allow auto-merge).
#   --client-side          → ship.sh creates the PR (no auto-merge),
#                             polls wait-for-pr-checks.sh in the
#                             foreground, then runs `gh pr merge`
#                             when checks go green. Terminal blocks
#                             until ship-or-fail. Use this when
#                             auto-merge isn't enabled on the repo.
#
# Output: ShipResult JSON (see schemas/ship-result.schema.json).
#
# Exit code: 0 for shipped / queued / skipped (clean states caller may
# proceed past); non-zero for ci-failed / ci-timeout / merge-failed /
# pr-failed (caller should not proceed).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
title=""
body=""
base=""
client_side=false
merge_strategy="squash"
profile_name=""
user_root=""
timeout_secs=1800
interval_secs=30
gh_bin="gh"
draft=false
allow_no_checks=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         target="${2:-}"; shift 2 ;;
    --target=*)       target="${1#--target=}"; shift ;;
    --title)          title="${2:-}"; shift 2 ;;
    --title=*)        title="${1#--title=}"; shift ;;
    --body)           body="${2:-}"; shift 2 ;;
    --body=*)         body="${1#--body=}"; shift ;;
    --base)           base="${2:-}"; shift 2 ;;
    --base=*)         base="${1#--base=}"; shift ;;
    --client-side)    client_side=true; shift ;;
    --merge-strategy) merge_strategy="${2:-squash}"; shift 2 ;;
    --merge-strategy=*) merge_strategy="${1#--merge-strategy=}"; shift ;;
    --profile)        profile_name="${2:-}"; shift 2 ;;
    --profile=*)      profile_name="${1#--profile=}"; shift ;;
    --user-root)      user_root="${2:-}"; shift 2 ;;
    --user-root=*)    user_root="${1#--user-root=}"; shift ;;
    --timeout)        timeout_secs="${2:-}"; shift 2 ;;
    --timeout=*)      timeout_secs="${1#--timeout=}"; shift ;;
    --interval)       interval_secs="${2:-}"; shift 2 ;;
    --interval=*)     interval_secs="${1#--interval=}"; shift ;;
    --gh)             gh_bin="${2:-}"; shift 2 ;;
    --gh=*)           gh_bin="${1#--gh=}"; shift ;;
    --draft)          draft=true; shift ;;
    --allow-no-checks) allow_no_checks=true; shift ;;
    -h|--help)        sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "$target is not a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"
[[ -n "$title" ]] || nyann::die "--title is required"
case "$merge_strategy" in
  squash|rebase|merge) ;;
  *) nyann::die "--merge-strategy must be one of: squash, rebase, merge" ;;
esac
[[ "$timeout_secs" =~ ^[0-9]+$ && "$timeout_secs" -ge 1 ]]   || nyann::die "--timeout must be a positive integer"
[[ "$interval_secs" =~ ^[0-9]+$ && "$interval_secs" -ge 1 ]] || nyann::die "--interval must be a positive integer"

mode="auto-merge"
$client_side && mode="client-side"

start_ts=$(date +%s)

emit_skipped() {
  local reason="$1"
  jq -n --arg target "$target" --arg mode "$mode" --arg reason "$reason" '{
    target: $target,
    mode: $mode,
    outcome: "skipped",
    elapsed_seconds: 0,
    skip_reason: $reason
  }'
  exit 0
}

# --- gh guard ---------------------------------------------------------------
# pr.sh would catch these too, but emitting a ShipResult-shaped skip
# here keeps the doctor / release skill consumers branching on the
# same JSON shape regardless of the underlying script.
if ! command -v "$gh_bin" >/dev/null 2>&1; then
  emit_skipped "gh-not-installed"
fi
if ! "$gh_bin" auth status >/dev/null 2>&1; then
  emit_skipped "gh-not-authenticated"
fi

# --- step 1: create the PR --------------------------------------------------

pr_args=(--target "$target" --title "$title" --gh "$gh_bin")
[[ -n "$body" ]] && pr_args+=(--body "$body")
[[ -n "$base" ]] && pr_args+=(--base "$base")
$draft && pr_args+=(--draft)

if [[ "$mode" == "auto-merge" ]]; then
  pr_args+=(--auto-merge --auto-merge-strategy "$merge_strategy")
  [[ -n "$profile_name" ]] && pr_args+=(--profile "$profile_name")
  [[ -n "$user_root" ]] && pr_args+=(--user-root "$user_root")
fi

pr_out=$("${_script_dir}/pr.sh" "${pr_args[@]}" 2>/dev/null) || true

# Empty stdout = pr.sh died hard; treat as pr-failed.
if [[ -z "$pr_out" ]]; then
  jq -n --arg target "$target" --arg mode "$mode" --argjson el "$(( $(date +%s) - start_ts ))" '{
    target: $target,
    mode: $mode,
    outcome: "pr-failed",
    elapsed_seconds: $el
  }'
  exit 3
fi

# Skipped by pr.sh (no remote, etc.).
if jq -e 'has("skipped")' <<<"$pr_out" >/dev/null 2>&1; then
  reason=$(jq -r '.reason // "pr-skipped"' <<<"$pr_out")
  emit_skipped "$reason"
fi

pr_url=$(jq -r '.url // empty' <<<"$pr_out")
if [[ -z "$pr_url" ]]; then
  jq -n --arg target "$target" --arg mode "$mode" --argjson el "$(( $(date +%s) - start_ts ))" '{
    target: $target,
    mode: $mode,
    outcome: "pr-failed",
    elapsed_seconds: $el
  }'
  exit 3
fi

# Extract PR number from URL: https://github.com/o/r/pull/N
pr_number=""
if [[ "$pr_url" =~ /pull/([0-9]+) ]]; then
  pr_number="${BASH_REMATCH[1]}"
fi

# --- step 2: branch on mode -------------------------------------------------

if [[ "$mode" == "auto-merge" ]]; then
  # pr.sh handled merge enablement. Inspect its outcome.
  am_outcome=$(jq -r '.auto_merge.outcome // empty' <<<"$pr_out")
  am_strategy=$(jq -r '.auto_merge.strategy // "squash"' <<<"$pr_out")
  if [[ "$am_outcome" == "enabled" ]]; then
    ship_outcome="queued"
    ship_exit=0
  elif [[ "$am_outcome" == "failed" ]]; then
    ship_outcome="merge-failed"
    ship_exit=3
  else
    ship_outcome="merge-failed"
    ship_exit=3
  fi

  jq -n \
    --arg target "$target" --arg mode "$mode" --arg outcome "$ship_outcome" \
    --arg pr_url "$pr_url" --arg strategy "$am_strategy" \
    --argjson el "$(( $(date +%s) - start_ts ))" \
    --argjson pr_num "${pr_number:-null}" \
    --arg merge_failed_reason "$(jq -r '.auto_merge.reason // ""' <<<"$pr_out")" \
    '{
      target: $target,
      mode: $mode,
      outcome: $outcome,
      elapsed_seconds: $el,
      pr_url: $pr_url,
      merge_strategy: $strategy
    }
    + (if $pr_num == null then {} else {pr_number: $pr_num} end)
    + (if $merge_failed_reason == "" then {} else {merge_failed_reason: $merge_failed_reason} end)'
  exit "$ship_exit"
fi

# --- client-side mode: poll then merge --------------------------------------

# Wait for checks. wait-for-pr-checks.sh exits 0 for pass/no-checks/skipped,
# 3 for fail/timeout. We forward the outcome to the ship summary.
checks_out=$("${_script_dir}/wait-for-pr-checks.sh" --target "$target" \
  --pr "$pr_number" --gh "$gh_bin" --timeout "$timeout_secs" --interval "$interval_secs" 2>/dev/null) || true

if [[ -z "$checks_out" ]] || [[ "$(jq -r 'type' <<<"$checks_out" 2>/dev/null || echo "")" != "object" ]]; then
  checks_out='{"outcome":"skipped","summary":{"total":0,"passing":0,"failing":0,"in_progress":0}}'
fi

checks_outcome=$(jq -r '.outcome // "skipped"' <<<"$checks_out")
checks_passing=$(jq -r '.summary.passing // 0' <<<"$checks_out")
checks_failing=$(jq -r '.summary.failing // 0' <<<"$checks_out")
checks_in_progress=$(jq -r '.summary.in_progress // 0' <<<"$checks_out")

ship_exit=0
ci_failed_reason=""
case "$checks_outcome" in
  pass)
    # Proceed to merge step.
    ;;
  no-checks)
    # The waiter returns no-checks on the FIRST poll if zero checks
    # are attached to the PR. After a fresh `gh pr create`, this is
    # almost always a race: workflows haven't registered yet, not
    # "this repo has no CI". Treating it as green merges the PR
    # before any gate runs — exactly what the user asked us to
    # prevent. Require explicit --allow-no-checks for repos that
    # genuinely run no PR checks.
    if $allow_no_checks; then
      nyann::warn "no checks attached to PR — proceeding because --allow-no-checks was set"
    else
      ship_outcome="ci-failed"
      ship_exit=3
      ci_failed_reason="no checks attached to PR — workflows may not have registered yet, or the repo has no PR CI. Re-run with --allow-no-checks if the empty state is intentional."
    fi
    ;;
  fail)     ship_outcome="ci-failed";  ship_exit=3 ;;
  timeout)  ship_outcome="ci-timeout"; ship_exit=3 ;;
  skipped)
    # Polling itself skipped (gh failed). Emit a ship-skipped wrapper.
    emit_skipped "checks-poll-skipped"
    ;;
  *)        ship_outcome="ci-failed";  ship_exit=3 ;;
esac

emit_with_checks() {
  local outcome="$1" exit_code="$2" merge_reason="${3:-}" ci_reason="${4:-}"
  jq -n \
    --arg target "$target" --arg mode "$mode" --arg outcome "$outcome" \
    --arg pr_url "$pr_url" --arg strategy "$merge_strategy" \
    --argjson el "$(( $(date +%s) - start_ts ))" \
    --argjson pr_num "${pr_number:-null}" \
    --arg co "$checks_outcome" \
    --argjson pa "$checks_passing" \
    --argjson fa "$checks_failing" \
    --argjson ip "$checks_in_progress" \
    --arg merge_reason "$merge_reason" \
    --arg ci_reason "$ci_reason" \
    '{
      target: $target,
      mode: $mode,
      outcome: $outcome,
      elapsed_seconds: $el,
      pr_url: $pr_url,
      merge_strategy: $strategy,
      checks: { outcome: $co, passing: $pa, failing: $fa, in_progress: $ip }
    }
    + (if $pr_num == null then {} else {pr_number: $pr_num} end)
    + (if $merge_reason == "" then {} else {merge_failed_reason: $merge_reason} end)
    + (if $ci_reason == "" then {} else {ci_failed_reason: $ci_reason} end)'
  exit "$exit_code"
}

if [[ -n "${ship_outcome:-}" ]] && [[ "$ship_outcome" != "shipped" ]]; then
  emit_with_checks "$ship_outcome" "$ship_exit" "" "$ci_failed_reason"
fi

# Checks green — merge.
merge_args=(pr merge "$pr_url")
case "$merge_strategy" in
  squash) merge_args+=(--squash) ;;
  rebase) merge_args+=(--rebase) ;;
  merge)  merge_args+=(--merge) ;;
esac
# Delete the head branch on merge — matches GitHub's `delete_branch_on_merge`
# repo setting that the audit recommends.
merge_args+=(--delete-branch)

merge_err=$(mktemp -t nyann-ship-merge.XXXXXX)
trap 'rm -f "$merge_err"' EXIT
if ( cd "$target" && "$gh_bin" "${merge_args[@]}" ) >/dev/null 2>"$merge_err"; then
  emit_with_checks "shipped" 0
else
  reason=$(head -c 500 "$merge_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  emit_with_checks "merge-failed" 3 "$reason"
fi
