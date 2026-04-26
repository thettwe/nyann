#!/usr/bin/env bash
# wait-for-pr-checks.sh — poll a PR's checks until pass / fail / timeout.
#
# Usage:
#   wait-for-pr-checks.sh --target <repo> [--pr <number>]
#                          [--timeout <sec>] [--interval <sec>]
#                          [--gh <path>]
#
# Behavior:
#   * Resolves PR number from --pr (preferred) or `gh pr view --json`
#     for the current branch.
#   * Polls `gh pr checks <num> --json name,status,conclusion,workflow`
#     every --interval seconds (default 30).
#   * Exits early as soon as any check has a failing conclusion.
#   * Bails with outcome:"timeout" after --timeout seconds (default 1800).
#   * Soft-skips when gh is missing/unauthenticated/PR-not-found.
#
# Output: PRChecksResult JSON (see schemas/pr-checks-result.schema.json)
# on stdout. Used by release.sh (gate tagging on green checks) and via
# the wait-for-pr-checks skill standalone.
#
# Exit code:
#   0   outcome in (pass, no-checks, skipped) — caller may proceed
#   3   outcome in (fail, timeout) — caller should NOT proceed

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
pr_number=""
timeout_secs=1800
interval_secs=30
gh_bin="gh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    target="${2:-}"; shift 2 ;;
    --target=*)  target="${1#--target=}"; shift ;;
    --pr)        pr_number="${2:-}"; shift 2 ;;
    --pr=*)      pr_number="${1#--pr=}"; shift ;;
    --timeout)   timeout_secs="${2:-}"; shift 2 ;;
    --timeout=*) timeout_secs="${1#--timeout=}"; shift ;;
    --interval)  interval_secs="${2:-}"; shift 2 ;;
    --interval=*) interval_secs="${1#--interval=}"; shift ;;
    --gh)        gh_bin="${2:-}"; shift 2 ;;
    --gh=*)      gh_bin="${1#--gh=}"; shift ;;
    -h|--help)   sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "$target is not a directory"
target="$(cd "$target" && pwd)"
[[ "$timeout_secs" =~ ^[0-9]+$ && "$timeout_secs" -ge 1 ]]   || nyann::die "--timeout must be a positive integer"
[[ "$interval_secs" =~ ^[0-9]+$ && "$interval_secs" -ge 1 ]] || nyann::die "--interval must be a positive integer"

emit_skipped() {
  local reason="$1" pr_payload="${2:-null}"
  jq -n --arg target "$target" --arg reason "$reason" --argjson pr "$pr_payload" '{
    target: $target,
    pr_number: $pr,
    outcome: "skipped",
    elapsed_seconds: 0,
    checks: [],
    summary: { total: 0, passing: 0, failing: 0, in_progress: 0 },
    skip_reason: $reason
  }'
  exit 0
}

# --- gh guard ---------------------------------------------------------------

if ! command -v "$gh_bin" >/dev/null 2>&1; then
  emit_skipped "gh-not-installed"
fi
if ! "$gh_bin" auth status >/dev/null 2>&1; then
  emit_skipped "gh-not-authenticated"
fi

# --- PR resolution ----------------------------------------------------------

if [[ -z "$pr_number" ]]; then
  # Resolve from current branch via `gh pr view`. The script runs from
  # within the repo (--target sets cwd), so gh picks it up.
  pr_view=$(cd "$target" && "$gh_bin" pr view --json number 2>/dev/null || echo '{}')
  pr_number=$(jq -r '.number // empty' <<<"$pr_view")
fi

if [[ -z "$pr_number" ]]; then
  emit_skipped "pr-not-resolved"
fi
if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
  emit_skipped "pr-not-resolved" "null"
fi

pr_number_json="$pr_number"

# --- poll loop --------------------------------------------------------------

start_ts=$(date +%s)
deadline=$(( start_ts + timeout_secs ))

while :; do
  now_ts=$(date +%s)
  elapsed=$(( now_ts - start_ts ))

  # Fetch the current state. Distinguish "gh succeeded with []" (real
  # no-checks — the PR genuinely has no checks attached) from "gh
  # itself failed" (network hiccup, auth flicker, rate limit). The
  # former is a clean exit; the latter must retry until timeout. The
  # earlier code coerced both into [] which let `total == 0` short-
  # circuit a non-pass into outcome:no-checks → caller (e.g. release
  # auto-tag) proceeded even though checks were never actually read.
  if raw=$(cd "$target" && "$gh_bin" pr checks "$pr_number" \
      --json name,status,conclusion,workflow 2>/dev/null); then
    gh_ok=true
  else
    gh_ok=false
    raw='[]'
  fi
  if [[ -z "$raw" ]]; then raw='[]'; fi
  if [[ "$(jq -r 'type' <<<"$raw" 2>/dev/null || echo "")" != "array" ]]; then
    raw='[]'
  fi

  total=$(jq 'length' <<<"$raw")

  # Default categorisation variables to safe values for the timeout +
  # sleep path; they only get populated when gh_ok succeeds below.
  passing=0
  failing=0
  in_progress=0

  # When gh failed, skip all "report-done" branches — we can't trust
  # the empty list as authoritative. Fall through to the timeout-or-
  # sleep step so the loop retries until either gh recovers or the
  # deadline hits. Without this gate, `total=0 + in_progress=0` would
  # take the "all done" path and falsely emit outcome:pass.
  if $gh_ok; then
    # No checks at all on the PR → pass immediately. Caller can proceed.
    if (( total == 0 )); then
      jq -n --arg target "$target" --argjson pr "$pr_number_json" --argjson el "$elapsed" '{
        target: $target,
        pr_number: $pr,
        outcome: "no-checks",
        elapsed_seconds: $el,
        checks: [],
        summary: { total: 0, passing: 0, failing: 0, in_progress: 0 }
      }'
      exit 0
    fi

    # Categorise. Status `completed` with a passing conclusion = passing;
    # `completed` with a failing conclusion = failing; anything else =
    # in_progress.
    passing=$(jq '[.[] | select(.status == "completed" and (.conclusion | IN("success","skipped","neutral")))] | length' <<<"$raw")
    failing=$(jq '[.[] | select(.status == "completed" and (.conclusion | IN("failure","cancelled","action_required","timed_out","stale")))] | length' <<<"$raw")
    in_progress=$(jq --argjson t "$total" --argjson p "$passing" --argjson f "$failing" \
      -n '$t - $p - $f')

    # Fail-fast on any failing check.
    if (( failing > 0 )); then
      jq -n --arg target "$target" --argjson pr "$pr_number_json" --argjson el "$elapsed" \
        --argjson checks "$raw" --argjson t "$total" --argjson p "$passing" \
        --argjson f "$failing" --argjson ip "$in_progress" '{
        target: $target,
        pr_number: $pr,
        outcome: "fail",
        elapsed_seconds: $el,
        checks: $checks,
        summary: { total: $t, passing: $p, failing: $f, in_progress: $ip }
      }'
      exit 3
    fi

    # All checks passing AND none in progress → done.
    if (( in_progress == 0 )); then
      jq -n --arg target "$target" --argjson pr "$pr_number_json" --argjson el "$elapsed" \
        --argjson checks "$raw" --argjson t "$total" --argjson p "$passing" \
        --argjson f "$failing" --argjson ip "$in_progress" '{
        target: $target,
        pr_number: $pr,
        outcome: "pass",
        elapsed_seconds: $el,
        checks: $checks,
        summary: { total: $t, passing: $p, failing: $f, in_progress: $ip }
      }'
      exit 0
    fi
  fi

  # Timeout?
  if (( now_ts >= deadline )); then
    jq -n --arg target "$target" --argjson pr "$pr_number_json" --argjson el "$elapsed" \
      --argjson checks "$raw" --argjson t "$total" --argjson p "$passing" \
      --argjson f "$failing" --argjson ip "$in_progress" '{
      target: $target,
      pr_number: $pr,
      outcome: "timeout",
      elapsed_seconds: $el,
      checks: $checks,
      summary: { total: $t, passing: $p, failing: $f, in_progress: $ip }
    }'
    exit 3
  fi

  # Stderr progress line so the caller (or a human watching) sees ticks.
  if $gh_ok; then
    nyann::log "PR #$pr_number checks: $passing/$total passing, $in_progress in progress (elapsed ${elapsed}s, deadline at ${timeout_secs}s)"
  else
    nyann::log "PR #$pr_number: gh fetch failed (transient — retrying; elapsed ${elapsed}s, deadline at ${timeout_secs}s)"
  fi
  sleep "$interval_secs"
done
