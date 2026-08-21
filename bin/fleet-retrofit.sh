#!/usr/bin/env bash
# fleet-retrofit.sh — plan and track a bulk fleet remediation run.
#
# THE SCRIPT LAYER NEVER MUTATES A REPO. This is the classification and
# bookkeeping engine for /nyann:fleet-retrofit: `--plan` classifies every
# registry entry read-only; the SKILL layer then walks the repos worst-first
# and drives the EXISTING single-repo machinery per repo — retrofit →
# plan-bootstrap.sh → preview.sh → per-repo confirm → bootstrap.sh (with its
# SHA-bound plan and its own BootRecord, so each repo stays individually
# undoable via undo-bootstrap). Outcomes come back via `--record`, and
# `--finalize` closes the run. Because mutation lives only behind the
# per-repo preview-and-confirm contract, a non-interactive context can run
# `--plan` freely but can never advance a repo past `pending` — bulk
# mutation without a human simply cannot happen.
#
# Usage:
#   fleet-retrofit.sh --plan [--bootstrap-missing] [--tag <t>] [--only <csv>]
#                     [--timeout <s>] [--fleet-file <path>] [--run-file <f>]
#                     [--retrofit <path>]
#   fleet-retrofit.sh --record --run-file <f> --repo <path> --action <a>
#                     [--exit-code <n>] [--detail <s>]
#   fleet-retrofit.sh --finalize --run-file <f>
#
# Modes:
#   --plan      Classify each fleet entry: `clean` / `drifted` (from a
#               report-only retrofit --json drift computation), `ungoverned`
#               (no boot record under memory/.nyann/bootstraps/ AND no
#               resolvable profile), or `error` (dead path / computation
#               failed — recorded, never fatal to the run). Emits a
#               FleetRunResult (phase=plan) on stdout; with --run-file, also
#               writes it there for the record/finalize phases.
#               Suggested actions: drifted → retrofit; ungoverned →
#               bootstrap with --bootstrap-missing, else skip (with the CTA
#               in detail); clean → none.
#   --record    Record one repo's outcome (action ∈ retrofitted |
#               bootstrapped | declined | skipped | failed) into the run
#               file; bumps phase to in-progress. Locked + atomic.
#   --finalize  Convert unreached `pending` rows to `skipped`, fill the
#               summary counts, stamp phase=final, and print the result.
#
#   --timeout <s>   per-repo cap for the drift computation (default 120;
#                   timeout/gtimeout when available, soft-uncapped otherwise).
#   --retrofit <p>  retrofit script to invoke per repo (default: alongside
#                   this script). Test seam, mirroring fleet-doctor --doctor.
#
# Exit codes (--plan): 0 nothing to do (all clean) · 4 at least one repo
# needs action or errored. --record/--finalize: 0 on success.
#
# Requires jq.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

mode=""
bootstrap_missing=false
tag=""
only=""
timeout=120
fleet_file="${HOME}/.claude/nyann/fleet.json"
run_file=""
retrofit_bin="${_script_dir}/retrofit.sh"
repo_path=""
action=""
exit_code=""
detail=""

set_mode() {
  [[ -z "$mode" ]] || nyann::die "only one of --plan / --record / --finalize may be given"
  mode="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)              set_mode plan; shift ;;
    --record)            set_mode record; shift ;;
    --finalize)          set_mode finalize; shift ;;
    --bootstrap-missing) bootstrap_missing=true; shift ;;
    --tag)               tag="${2-}"; shift 2 ;;
    --tag=*)             tag="${1#--tag=}"; shift ;;
    --only)              only="${2-}"; shift 2 ;;
    --only=*)            only="${1#--only=}"; shift ;;
    --timeout)           timeout="${2-}"; shift 2 ;;
    --timeout=*)         timeout="${1#--timeout=}"; shift ;;
    --fleet-file)        fleet_file="${2-}"; shift 2 ;;
    --fleet-file=*)      fleet_file="${1#--fleet-file=}"; shift ;;
    --run-file)          run_file="${2-}"; shift 2 ;;
    --run-file=*)        run_file="${1#--run-file=}"; shift ;;
    --retrofit)          retrofit_bin="${2-}"; shift 2 ;;
    --retrofit=*)        retrofit_bin="${1#--retrofit=}"; shift ;;
    --repo)              repo_path="${2-}"; shift 2 ;;
    --repo=*)            repo_path="${1#--repo=}"; shift ;;
    --action)            action="${2-}"; shift 2 ;;
    --action=*)          action="${1#--action=}"; shift ;;
    --exit-code)         exit_code="${2-}"; shift 2 ;;
    --exit-code=*)       exit_code="${1#--exit-code=}"; shift ;;
    --detail)            detail="${2-}"; shift 2 ;;
    --detail=*)          detail="${1#--detail=}"; shift ;;
    -h|--help)           sed -n '3,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$mode" ]] || nyann::die "one of --plan / --record / --finalize is required"
[[ "$timeout" =~ ^[0-9]+$ ]] || nyann::die "--timeout must be a non-negative integer (got: $timeout)"

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# run_capped <secs> <cmd...> — the session-triage timeout pattern.
run_capped() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=$((secs + 5))s "${secs}s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=$((secs + 5))s "${secs}s" "$@"
  else
    "$@"
  fi
}

# write_run_file <json> — atomic replace under a lock (record/finalize can
# race a concurrent skill step otherwise).
write_run_file() {
  local json="$1"
  local lock="${run_file}.lock"
  local tmp="${run_file}.tmp.$$"
  nyann::lock "$lock"
  trap 'rm -f "$tmp"; nyann::unlock "$lock"' EXIT
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$run_file"
  nyann::unlock "$lock"
  trap - EXIT
}

read_run_file() {
  [[ -n "$run_file" ]] || nyann::die "--run-file is required for $mode"
  [[ -f "$run_file" ]] || nyann::die "run file not found: $run_file"
  jq -e 'type == "object" and has("repos")' >/dev/null 2>&1 "$run_file" \
    || nyann::die "run file is not a FleetRunResult: $run_file"
  cat "$run_file"
}

# --- plan --------------------------------------------------------------------

run_plan() {
  local registry="[]"
  if [[ -f "$fleet_file" ]]; then
    registry=$(jq -e 'if type == "array" then . else empty end' "$fleet_file" 2>/dev/null) || {
      nyann::warn "fleet registry is not a JSON array — treating as empty: $fleet_file"
      registry="[]"
    }
  fi
  if [[ -n "$tag" ]]; then
    registry=$(jq --arg t "$tag" 'map(select((.tags // []) | index($t) != null))' <<<"$registry")
  fi
  if [[ -n "$only" ]]; then
    local only_json
    only_json=$(printf '%s' "$only" | tr ',' '\n' | jq -R . | jq -s 'map(select(. != ""))')
    registry=$(jq --argjson names "$only_json" \
      'map(select((.name // (.path | split("/") | last)) as $n | ($names | index($n)) != null))' <<<"$registry")
  fi

  local count rows="[]" i=0 entry path name pin prof prof_src
  local classification suggested drift_json det report rc drifted
  count=$(jq 'length' <<<"$registry")

  while (( i < count )); do
    entry=$(jq -c ".[$i]" <<<"$registry")
    path=$(jq -r '.path' <<<"$entry")
    name=$(jq -r '.name // (.path | split("/") | last)' <<<"$entry")
    pin=$(jq -r '.profile // ""' <<<"$entry")
    nyann::log "fleet: classifying $name ($((i + 1))/$count)"

    classification="" suggested="none" drift_json="null" det=""
    IFS=$'\t' read -r prof prof_src < <(nyann::resolve_repo_profile "$path" "$pin")

    if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      classification="error"
      det="path is not a git repo (run fleet.sh --prune?)"
    elif ! compgen -G "$path/memory/.nyann/bootstraps/*/manifest.json" >/dev/null 2>&1 \
         && [[ "$prof_src" == "fallback" ]]; then
      # No boot record AND no resolvable profile → nyann never set this
      # repo up and nothing says what to govern it against.
      classification="ungoverned"
      if $bootstrap_missing; then
        suggested="bootstrap"
      else
        suggested="skip"
        det="ungoverned — re-run with --bootstrap-missing to include it"
      fi
    else
      rc=0
      report=$(run_capped "$timeout" bash "$retrofit_bin" \
        --target "$path" --profile "$prof" --report-only --json 2>/dev/null) || rc=$?
      if (( rc == 124 || rc == 137 )); then
        classification="error"
        det="drift computation timed out after ${timeout}s"
      elif ! jq -e 'type == "object" and has("summary")' >/dev/null 2>&1 <<<"$report"; then
        classification="error"
        det="drift computation failed (rc=$rc)"
      else
        # retrofit --json always exits 0, so drift is derived from the
        # report itself (mirrors the doctor text-mode warn/critical rules).
        drifted=$(jq -r '
          def n(x): (x // 0);
          ( n(.summary.missing) + n(.summary.misconfigured)
            + n(.summary.non_compliant_commits) + n(.summary.broken_links)
            + n(.summary.orphans) + n(.summary.stale_docs)
            + n(.summary.misplaced) + n(.summary.subsystem_errors) ) as $total |
          if $total > 0
             or (.summary.claude_md_status == "warn"
                 or .summary.claude_md_status == "absent"
                 or .summary.claude_md_status == "error")
          then "yes" else "no" end' <<<"$report" 2>/dev/null || echo no)
        drift_json=$(jq -c '{missing: (.summary.missing // 0),
                             misconfigured: (.summary.misconfigured // 0),
                             non_compliant: (.summary.non_compliant_commits // 0)}' <<<"$report")
        if [[ "$drifted" == "yes" ]]; then
          classification="drifted"
          suggested="retrofit"
        else
          classification="clean"
        fi
      fi
    fi

    rows=$(jq \
      --arg n "$name" --arg p "$path" --arg prof "$prof" --arg src "$prof_src" \
      --arg c "$classification" --arg s "$suggested" --arg det "$det" \
      --argjson d "$drift_json" '
      . + [{name:$n, path:$p, profile:$prof, profile_source:$src,
            classification:$c, suggested_action:$s, drift:$d,
            action: (if $c == "clean" then "clean"
                     elif $c == "error" then "failed"
                     elif $s == "skip" then "skipped"
                     else "pending" end),
            exit_code: null,
            detail: (if $det == "" then null else $det end)}]' <<<"$rows")
    i=$((i + 1))
  done

  local result
  result=$(jq -n --arg ts "$(now)" --argjson bm "$bootstrap_missing" --argjson rows "$rows" '
    ($rows | sort_by(
       if   .classification == "error"      then 0
       elif .classification == "drifted"    then 1
       elif .classification == "ungoverned" then 2
       else 3 end)) as $repos |
    {generated_at: $ts, phase: "plan", bootstrap_missing: $bm, repos: $repos,
     summary: {
       count: ($repos | length),
       clean:      ([$repos[] | select(.classification == "clean")] | length),
       drifted:    ([$repos[] | select(.classification == "drifted")] | length),
       ungoverned: ([$repos[] | select(.classification == "ungoverned")] | length),
       errors:     ([$repos[] | select(.classification == "error")] | length),
       retrofitted: 0, bootstrapped: 0, declined: 0,
       skipped:    ([$repos[] | select(.action == "skipped")] | length),
       failed:     ([$repos[] | select(.action == "failed")] | length)
     }}')

  if [[ -n "$run_file" ]]; then
    mkdir -p "$(dirname "$run_file")" 2>/dev/null || true
    write_run_file "$result"
  fi
  printf '%s\n' "$result"

  local pending
  pending=$(jq -r '([.repos[] | select(.action == "pending")] | length)
                   + ([.repos[] | select(.classification == "error")] | length)' <<<"$result")
  if [[ "$pending" != "0" ]]; then
    return 4
  fi
  return 0
}

# --- record ------------------------------------------------------------------

run_record() {
  case "$action" in
    retrofitted|bootstrapped|declined|skipped|failed) : ;;
    *) nyann::die "--action must be one of retrofitted|bootstrapped|declined|skipped|failed (got: ${action:-<empty>})" ;;
  esac
  [[ -n "$repo_path" ]] || nyann::die "--repo <path> is required for --record"
  if [[ -n "$exit_code" ]] && ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
    nyann::die "--exit-code must be a non-negative integer (got: $exit_code)"
  fi
  local current match updated
  current=$(read_run_file)
  match=$(jq -r --arg p "$repo_path" '[.repos[] | select(.path == $p)] | length' <<<"$current")
  [[ "$match" == "0" ]] && nyann::die "no repo with path $repo_path in the run file"
  updated=$(jq --arg p "$repo_path" --arg a "$action" \
    --arg ec "$exit_code" --arg det "$detail" '
    .phase = "in-progress"
    | .repos = (.repos | map(if .path == $p
        then .action = $a
           | .exit_code = (if $ec == "" then null else ($ec | tonumber) end)
           | .detail = (if $det == "" then .detail else $det end)
        else . end))' <<<"$current")
  write_run_file "$updated"
  nyann::log "fleet: recorded $action for $repo_path"
}

# --- finalize ----------------------------------------------------------------

run_finalize() {
  local current final
  current=$(read_run_file)
  final=$(jq --arg ts "$(now)" '
    .phase = "final"
    | .repos = (.repos | map(if .action == "pending"
        then .action = "skipped"
           | .detail = (.detail // "run ended before this repo was reached")
        else . end))
    | .summary = {
        count: (.repos | length),
        clean:       ([.repos[] | select(.classification == "clean")] | length),
        drifted:     ([.repos[] | select(.classification == "drifted")] | length),
        ungoverned:  ([.repos[] | select(.classification == "ungoverned")] | length),
        errors:      ([.repos[] | select(.classification == "error")] | length),
        retrofitted: ([.repos[] | select(.action == "retrofitted")] | length),
        bootstrapped:([.repos[] | select(.action == "bootstrapped")] | length),
        declined:    ([.repos[] | select(.action == "declined")] | length),
        skipped:     ([.repos[] | select(.action == "skipped")] | length),
        failed:      ([.repos[] | select(.action == "failed")] | length)
      }' <<<"$current")
  write_run_file "$final"
  printf '%s\n' "$final"
}

case "$mode" in
  plan)     run_plan ;;
  record)   run_record ;;
  finalize) run_finalize ;;
esac
