#!/usr/bin/env bash
# fleet-doctor.sh — bulk read-only audit across the fleet registry.
#
# Iterates the fleet registry (bin/fleet.sh) and runs the existing per-repo
# doctor (bin/doctor.sh --json) against each entry, aggregating the results
# into one FleetReport (schemas/fleet-report.schema.json) and rendering a
# worst-first health dashboard. The fleet layer is ITERATION ONLY — every
# audit fact comes from the single-repo doctor contract; nothing is
# re-implemented here.
#
# Usage:
#   fleet-doctor.sh [--json | --markdown | --explain]
#                   [--cached] [--drift]
#                   [--tag <t>] [--only <name,...>]
#                   [--jobs <n>] [--timeout <s>] [--persist]
#                   [--stale-days <n>] [--threshold <n>]
#                   [--fleet-file <path>] [--gh <bin>]
#
# Modes / flags:
#   (default)     Render the fleet dashboard as text on stdout.
#   --json        Emit the FleetReport JSON instead (no dashboard render).
#   --markdown    Emit a paste-ready markdown table (names/categories pass
#                 nyann::safe_md_cell). Mutually exclusive with --json.
#   --explain     After the dashboard, pipe each drifted repo's report
#                 through bin/explain-diff.sh for a plain-English narrative
#                 (implies --drift; live mode only).
#   --cached      INSTANT mode: read each repo's persisted memory/health.json
#                 instead of running doctor. Entries older than --stale-days
#                 are flagged `stale`; repos with no history are `missing`.
#                 The header labels the board `cached` so a stale board is
#                 never mistaken for a live one. Excludes --drift/--persist.
#   --drift       Live mode only: append repo-tagged drift findings per
#                 drifted repo, and embed each drifted repo's full doctor
#                 JSON under repos[].drift_report in --json output.
#   --tag <t>     Only entries whose tags[] include <t>.
#   --only <csv>  Only entries whose name is in the CSV list.
#   --jobs <n>    Opt-in parallelism (default 1, max 8). Safe: doctor is
#                 read-only and --persist writes land in each repo's OWN
#                 memory/health.json; per-repo output goes to temp files and
#                 is merged after, so logs never interleave into the report.
#   --timeout <s> Per-repo cap (default 120). Uses timeout/gtimeout when
#                 available; otherwise uncapped (same soft degradation as
#                 session-triage). A timed-out repo is status=error and the
#                 run continues.
#   --persist     Pass through to each repo's doctor (records the score into
#                 that repo's own trend series).
#   --stale-days  Cached-mode staleness threshold (default 7).
#   --threshold   Summary "below_threshold" cutoff (default 70).
#   --gh <bin>    Forwarded to doctor.sh (gh binary override, for tests /
#                 degraded environments).
#   --doctor <p>  doctor script to invoke per repo (default: alongside this
#                 script). Test seam, mirroring sentinel-aggregate --sentinel.
#
# Profile resolution per repo (never prompts mid-iteration):
#   1. fleet-entry `profile` pin                       → profile_source=pin
#   2. the repo's .nyann/profile hint file             → profile_source=repo
#   3. CLAUDE.md profile declaration (same patterns
#      explain-state.sh infers from)                   → profile_source=repo
#   4. `default`                                       → profile_source=fallback
# Fallback rows are marked so the dashboard shows which repos were audited
# against a guess; the skill layer offers to pin them AFTER the run.
#
# Exit codes (worst-of across repos, mirroring doctor's own 0/4/5):
#   0 — every repo clean
#   4 — any repo warned / stale / missing / errored
#   5 — any repo critical
#
# Requires jq. git for repo validation.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

json_out=false
markdown=false
explain=false
cached=false
drift=false
tag=""
only=""
jobs=1
timeout=120
persist=false
stale_days=7
threshold=70
fleet_file="${HOME}/.claude/nyann/fleet.json"
gh_bin=""
doctor_bin="${_script_dir}/doctor.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)          json_out=true; shift ;;
    --markdown)      markdown=true; shift ;;
    --explain)       explain=true; drift=true; shift ;;
    --cached)        cached=true; shift ;;
    --drift)         drift=true; shift ;;
    --tag)           tag="${2-}"; shift 2 ;;
    --tag=*)         tag="${1#--tag=}"; shift ;;
    --only)          only="${2-}"; shift 2 ;;
    --only=*)        only="${1#--only=}"; shift ;;
    --jobs)          jobs="${2-}"; shift 2 ;;
    --jobs=*)        jobs="${1#--jobs=}"; shift ;;
    --timeout)       timeout="${2-}"; shift 2 ;;
    --timeout=*)     timeout="${1#--timeout=}"; shift ;;
    --persist)       persist=true; shift ;;
    --stale-days)    stale_days="${2-}"; shift 2 ;;
    --stale-days=*)  stale_days="${1#--stale-days=}"; shift ;;
    --threshold)     threshold="${2-}"; shift 2 ;;
    --threshold=*)   threshold="${1#--threshold=}"; shift ;;
    --fleet-file)    fleet_file="${2-}"; shift 2 ;;
    --fleet-file=*)  fleet_file="${1#--fleet-file=}"; shift ;;
    --gh)            gh_bin="${2-}"; shift 2 ;;
    --gh=*)          gh_bin="${1#--gh=}"; shift ;;
    --doctor)        doctor_bin="${2-}"; shift 2 ;;
    --doctor=*)      doctor_bin="${1#--doctor=}"; shift ;;
    -h|--help)       sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

$json_out && $markdown && nyann::die "--json and --markdown are mutually exclusive"
$explain && $json_out && nyann::die "--explain and --json are mutually exclusive (narrative vs. JSON)"
$explain && $markdown && nyann::die "--explain and --markdown are mutually exclusive"
if $cached && $drift; then
  nyann::die "--drift needs a live run — drift findings cannot come from a cached score (drop --cached)"
fi
if $cached && $persist; then
  nyann::die "--persist needs a live run — cached mode never invokes doctor (drop --cached)"
fi
for _n in jobs timeout stale_days threshold; do
  _v="${!_n}"
  [[ "$_v" =~ ^[0-9]+$ ]] || nyann::die "--${_n//_/-} must be a non-negative integer (got: $_v)"
done
if (( jobs < 1 || jobs > 8 )); then
  nyann::die "--jobs must be between 1 and 8 (got: $jobs)"
fi

# --- Registry read + filters --------------------------------------------------

registry="[]"
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
  only_json=$(printf '%s' "$only" | tr ',' '\n' | jq -R . | jq -s 'map(select(. != ""))')
  registry=$(jq --argjson names "$only_json" \
    'map(select((.name // (.path | split("/") | last)) as $n | ($names | index($n)) != null))' <<<"$registry")
fi

repo_count=$(jq 'length' <<<"$registry")

workdir=$(mktemp -d -t nyann-fleet-doctor.XXXXXX)
trap 'rm -rf "$workdir"' EXIT

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# run_capped <secs> <cmd...> — the session-triage timeout pattern: GNU/BSD
# timeout (or gtimeout) when present, plain execution otherwise. The kill
# grace period trails the cap by 5s.
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

# trend_fields <path> — prints a JSON object {direction, delta, sparkline,
# health_age_days, last_score} from the repo's persisted health history
# (all-null object when there is none).
trend_fields() {
  local path="$1" hf="$1/memory/health.json" trend age last
  if [[ ! -f "$hf" ]]; then
    echo '{"direction":null,"delta":null,"sparkline":null,"health_age_days":null,"last_score":null}'
    return 0
  fi
  trend=$("${_script_dir}/health-trend.sh" --target "$path" --format json 2>/dev/null || echo '{}')
  age=$(jq -r 'try ((now - (.scores[-1].timestamp | fromdateiso8601)) / 86400 | floor) catch null' "$hf" 2>/dev/null || echo null)
  [[ "$age" =~ ^[0-9]+$ ]] || age=null
  last=$(jq -r 'try .scores[-1].score catch null' "$hf" 2>/dev/null || echo null)
  [[ "$last" =~ ^[0-9]+$ ]] || last=null
  jq -n --argjson t "$trend" --argjson age "$age" --argjson last "$last" '{
    direction: ($t.direction // null),
    delta: ($t.delta // null),
    sparkline: ($t.sparkline // null),
    health_age_days: $age,
    last_score: $last
  }'
}

# audit_one <idx> <entry-json> — audit a single fleet entry and write its
# FleetReport repo row to $workdir/<idx>.json. Never exits non-zero: every
# failure becomes a status=error row so one broken repo can't kill the run.
audit_one() {
  local idx="$1" entry="$2"
  local path name pin prof prof_src tf out rc sev err_file row
  path=$(jq -r '.path' <<<"$entry")
  name=$(jq -r '.name // (.path | split("/") | last)' <<<"$entry")
  pin=$(jq -r '.profile // ""' <<<"$entry")

  emit_error() {
    jq -n --arg n "$name" --arg p "$path" --arg prof "${2-default}" \
      --arg src "${3-fallback}" --arg e "$1" \
      '{name:$n, path:$p, score:null, direction:null, delta:null, sparkline:null,
        drift:null, worst_category:null, profile:$prof, profile_source:$src,
        health_age_days:null, status:"error", exit_code:null, error:$e}' \
      > "$workdir/$idx.json"
  }

  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    emit_error "path is not a git repo (run fleet.sh --prune?)"
    return 0
  fi

  IFS=$'\t' read -r prof prof_src < <(nyann::resolve_repo_profile "$path" "$pin")
  tf=$(trend_fields "$path")

  if $cached; then
    jq -n --arg n "$name" --arg p "$path" --arg prof "$prof" --arg src "$prof_src" \
      --argjson t "$tf" --argjson stale_days "$stale_days" '
      ($t.last_score) as $score |
      {name:$n, path:$p, score:$score,
       direction:$t.direction, delta:$t.delta, sparkline:$t.sparkline,
       drift:null, worst_category:null, profile:$prof, profile_source:$src,
       health_age_days:$t.health_age_days,
       status: (if $score == null then "missing"
                elif ($t.health_age_days // 0) > $stale_days then "stale"
                else "ok" end),
       exit_code:null, error:null}' > "$workdir/$idx.json"
    return 0
  fi

  local doctor_args=(--target "$path" --profile "$prof" --json)
  $persist && doctor_args+=(--persist)
  [[ -n "$gh_bin" ]] && doctor_args+=(--gh "$gh_bin")

  err_file="$workdir/$idx.err"
  rc=0
  out=$(run_capped "$timeout" bash "$doctor_bin" "${doctor_args[@]}" 2>"$err_file") || rc=$?

  case "$rc" in
    0|4|5) : ;;
    124|137)
      emit_error "doctor timed out after ${timeout}s" "$prof" "$prof_src"
      return 0 ;;
    *)
      emit_error "doctor failed (rc=$rc): $(tail -n1 "$err_file" 2>/dev/null | head -c 200)" "$prof" "$prof_src"
      return 0 ;;
  esac
  if ! jq -e 'type == "object" and has("summary")' >/dev/null 2>&1 <<<"$out"; then
    emit_error "doctor emitted an invalid report (rc=$rc)" "$prof" "$prof_src"
    return 0
  fi

  # Re-read the trend AFTER the doctor run so a --persist score is reflected.
  $persist && tf=$(trend_fields "$path")

  # Derive the repo's 0/4/5 severity from the report JSON using doctor's
  # TEXT-mode exit rules. doctor --json itself exits 0 for core drift (only
  # the probe escalations move its rc), so the rc alone under-reports; take
  # the max of both so a probe-only escalation still counts.
  sev=$(jq -r '
    def n(x): (x // 0);
    ( n(.summary.missing) > 0
      or n(.summary.broken_links) > 0
      or (.summary.claude_md_status == "error")
      or n(.docs_drift.summary.by_severity.critical) > 0
      or n(.iac_drift.summary.by_severity.critical) > 0
      or n(.protection_audit.summary.critical) > 0 ) as $crit |
    ( n(.summary.misconfigured) > 0
      or n(.summary.non_compliant_commits) > 0
      or n(.summary.orphans) > 0
      or n(.summary.stale_docs) > 0
      or n(.summary.misplaced) > 0
      or n(.summary.subsystem_errors) > 0
      or (.summary.claude_md_status == "warn" or .summary.claude_md_status == "absent")
      or n(.docs_drift.summary.by_severity.high) > 0
      or n(.iac_drift.summary.by_severity.high) > 0
      or n(.protection_audit.summary.warn) > 0 ) as $warn |
    if $crit then 5 elif $warn then 4 else 0 end' <<<"$out" 2>/dev/null || echo 0)
  [[ "$sev" =~ ^[0-9]+$ ]] || sev=0
  (( rc > sev )) && sev=$rc

  row=$(jq -n --arg n "$name" --arg p "$path" --arg prof "$prof" --arg src "$prof_src" \
    --argjson t "$tf" --argjson rc "$sev" --argjson d "$out" '
    {name:$n, path:$p,
     score: ($d.health_score.score // null),
     direction:$t.direction, delta:$t.delta, sparkline:$t.sparkline,
     drift: {missing: ($d.summary.missing // 0),
             misconfigured: ($d.summary.misconfigured // 0),
             non_compliant: ($d.summary.non_compliant_commits // 0)},
     worst_category: ($d.health_score.breakdown // {} | to_entries
                      | map(select(.value < 0)) | sort_by(.value)
                      | (.[0].key // null)),
     profile:$prof, profile_source:$src,
     health_age_days:$t.health_age_days,
     status:"ok", exit_code:$rc, error:null}')
  if $drift && (( sev != 0 )); then
    row=$(jq --argjson d "$out" '. + {drift_report: $d}' <<<"$row")
  fi
  printf '%s\n' "$row" > "$workdir/$idx.json"
  return 0
}

# --- Iterate ------------------------------------------------------------------

if (( repo_count > 0 )); then
  i=0
  batch=0
  while (( i < repo_count )); do
    entry=$(jq -c ".[$i]" <<<"$registry")
    ename=$(jq -r '.name // (.path | split("/") | last)' <<<"$entry")
    idx=$(printf '%03d' "$i")
    if (( jobs == 1 )); then
      nyann::log "fleet: auditing $ename ($((i + 1))/$repo_count)"
      audit_one "$idx" "$entry"
    else
      nyann::log "fleet: auditing $ename ($((i + 1))/$repo_count, parallel)"
      audit_one "$idx" "$entry" &
      batch=$((batch + 1))
      # bash-3.2-portable batching: a plain `wait` barrier per group of
      # --jobs (no `wait -n`). Slightly coarser than a rolling pool but
      # portable to the macOS system bash.
      if (( batch >= jobs )); then
        wait
        batch=0
      fi
    fi
    i=$((i + 1))
  done
  wait
fi

# --- Assemble the FleetReport -------------------------------------------------

rows="[]"
if compgen -G "$workdir/*.json" >/dev/null 2>&1; then
  rows=$(jq -s '.' "$workdir"/*.json)
fi

mode_str="live"
$cached && mode_str="cached"

report=$(jq -n \
  --arg ts "$(now)" \
  --arg mode "$mode_str" \
  --argjson thr "$threshold" \
  --argjson rows "$rows" '
  ($rows | sort_by(if .score == null then -1 else .score end)) as $repos |
  ([$repos[].score | select(. != null)]) as $scores |
  {generated_at: $ts, mode: $mode, repos: $repos,
   summary: {
     count: ($repos | length),
     avg: (if ($scores | length) > 0 then (($scores | add) / ($scores | length) | floor) else null end),
     min: (if ($scores | length) > 0 then ($scores | min) else null end),
     max: (if ($scores | length) > 0 then ($scores | max) else null end),
     below_threshold: ([$scores[] | select(. < $thr)] | length),
     threshold: $thr,
     critical_repos: ([$repos[] | select(.exit_code == 5)] | length)
   }}')

# --- Exit code (worst-of) -----------------------------------------------------

rc=0
any_warn=$(jq -r '[.repos[] | select(.exit_code == 4 or .status == "stale" or .status == "missing" or .status == "error")] | length' <<<"$report")
any_crit=$(jq -r '[.repos[] | select(.exit_code == 5)] | length' <<<"$report")
(( any_warn > 0 )) && rc=4
(( any_crit > 0 )) && rc=5

# --- Output -------------------------------------------------------------------

if $json_out; then
  printf '%s\n' "$report"
  exit "$rc"
fi

render_trend_cell() {
  # $1=direction $2=delta
  case "$1" in
    up)     printf '↑%s' "${2#-}" ;;
    down)   printf '↓%s' "${2#-}" ;;
    stable) printf '→' ;;
    *)      printf ' ' ;;
  esac
}

if $markdown; then
  printf '## Fleet health (%s)\n\n' "$(jq -r '.mode' <<<"$report")"
  printf '%s repos · avg %s · min %s · %s below %s · %s critical\n\n' \
    "$(jq -r '.summary.count' <<<"$report")" \
    "$(jq -r '.summary.avg // "—"' <<<"$report")" \
    "$(jq -r '.summary.min // "—"' <<<"$report")" \
    "$(jq -r '.summary.below_threshold' <<<"$report")" \
    "$(jq -r '.summary.threshold' <<<"$report")" \
    "$(jq -r '.summary.critical_repos' <<<"$report")"
  printf '| Repo | Score | Trend | Drift (miss/mis) | Worst | Profile | Status |\n'
  printf '|---|---|---|---|---|---|---|\n'
  count=$(jq -r '.repos | length' <<<"$report")
  j=0
  while (( j < count )); do
    r=$(jq -c ".repos[$j]" <<<"$report")
    # Every field maps to a NON-EMPTY sentinel: tab is IFS whitespace, so an
    # empty @tsv field would collapse and shift every later column.
    IFS=$'\t' read -r r_name r_score r_dir r_delta r_miss r_mis r_worst r_prof r_src r_status < <(
      jq -r '[.name, (.score // "—"), (.direction // "-"), (.delta // 0),
              (.drift.missing // "—"), (.drift.misconfigured // "—"),
              (.worst_category // "—"), .profile, .profile_source, .status] | @tsv' <<<"$r")
    prof_cell="$(nyann::safe_md_cell "$r_prof")"
    [[ "$r_src" == "fallback" ]] && prof_cell="${prof_cell} (?)"
    printf '| %s | %s | %s | %s/%s | %s | %s | %s |\n' \
      "$(nyann::safe_md_cell "$r_name")" "$r_score" \
      "$(render_trend_cell "$r_dir" "$r_delta")" \
      "$r_miss" "$r_mis" \
      "$(nyann::safe_md_cell "$r_worst")" \
      "$prof_cell" "$r_status"
    j=$((j + 1))
  done
else
# Text dashboard.
printf '\nFLEET HEALTH (%s) — %s repos · avg %s · min %s · %s below %s · %s critical\n\n' \
  "$(jq -r '.mode' <<<"$report")" \
  "$(jq -r '.summary.count' <<<"$report")" \
  "$(jq -r '.summary.avg // "—"' <<<"$report")" \
  "$(jq -r '.summary.min // "—"' <<<"$report")" \
  "$(jq -r '.summary.below_threshold' <<<"$report")" \
  "$(jq -r '.summary.threshold' <<<"$report")" \
  "$(jq -r '.summary.critical_repos' <<<"$report")"

count=$(jq -r '.repos | length' <<<"$report")
if (( count == 0 )); then
  printf '  (fleet registry is empty — add repos with fleet.sh --add / --scan)\n'
else
  printf '  %-20s %5s  %-5s %-10s %-9s %-14s %s\n' NAME SCORE TREND SPARK MISS/MIS WORST PROFILE
  j=0
  while (( j < count )); do
    r=$(jq -c ".repos[$j]" <<<"$report")
    IFS=$'\t' read -r r_name r_status r_err < <(jq -r '[.name, .status, (.error // "")] | @tsv' <<<"$r")
    case "$r_status" in
      error)
        printf '  %-20s %5s  %s\n' "${r_name:0:20}" "—" "ERROR: $r_err"
        ;;
      missing)
        printf '  %-20s %5s  no health history — run doctor --persist first\n' "${r_name:0:20}" "—"
        ;;
      *)
        # NON-EMPTY sentinels throughout: tab is IFS whitespace, so an empty
        # @tsv field would collapse and shift every later column.
        IFS=$'\t' read -r r_score r_dir r_delta r_spark r_miss r_mis r_worst r_prof r_src r_age < <(
          jq -r '[(.score // "—"), (.direction // "-"), (.delta // 0), (.sparkline // "-"),
                  (.drift.missing // "—"), (.drift.misconfigured // "—"),
                  (.worst_category // "—"), .profile, .profile_source,
                  (.health_age_days // "-")] | @tsv' <<<"$r")
        prof_cell="$r_prof"
        [[ "$r_src" == "fallback" ]] && prof_cell="${prof_cell}?"
        suffix=""
        [[ "$r_status" == "stale" ]] && suffix="  (stale ${r_age}d)"
        printf '  %-20s %5s  %-5s %-10s %-9s %-14s %s%s\n' \
          "${r_name:0:20}" "$r_score" \
          "$(render_trend_cell "$r_dir" "$r_delta")" \
          "${r_spark:0:10}" "${r_miss}/${r_mis}" "${r_worst:0:14}" \
          "$prof_cell" "$suffix"
        ;;
    esac
    j=$((j + 1))
  done
  if [[ "$(jq -r '[.repos[] | select(.profile_source == "fallback")] | length' <<<"$report")" != "0" ]]; then
    # Backticks are literal markdown, not command substitution.
    # shellcheck disable=SC2016
    printf '\n  ? = audited against the `default` profile (no pin or repo hint) — pin one via fleet.sh --add <path> --profile <p>\n'
  fi
fi
fi  # markdown / text

# --- Drift roll-up (--drift, live mode) ---------------------------------------
# Repo-tagged findings per drifted repo, rendered in the active flavour
# (indented glyph lines for text, bullet list under a bold name for markdown).

if $drift; then
  bullet="  "
  $markdown && bullet="- "
  drifted=$(jq -r '[.repos[] | select(.drift_report != null)] | length' <<<"$report")
  count=$(jq -r '.repos | length' <<<"$report")
  if (( drifted > 0 )); then
    if $markdown; then
      printf '\n### Drift findings (%s repos)\n' "$drifted"
    else
      printf '\nDRIFT FINDINGS (%s repos):\n' "$drifted"
    fi
    j=0
    while (( j < count )); do
      r=$(jq -c ".repos[$j] | select(.drift_report != null) // empty" <<<"$report")
      if [[ -n "$r" ]]; then
        if $markdown; then
          # Backticks are literal markdown code-span delimiters.
          # shellcheck disable=SC2016
          printf '\n**%s** (`%s`)\n' \
            "$(nyann::safe_md_cell "$(jq -r '.name' <<<"$r")")" \
            "$(jq -r '.path' <<<"$r")"
        else
          printf '\n── %s (%s) ──\n' "$(jq -r '.name' <<<"$r")" "$(jq -r '.path' <<<"$r")"
        fi
        jq -r --arg b "$bullet" '.drift_report |
          ([.missing[]? | $b + "✗ missing: " + .path + (if .detail then "   # " + .detail else "" end)]
           + [.misconfigured[]? | $b + "⚠ misconfigured: " + .path + " — " + .reason])
          | (.[0:10][]), (if length > 10 then $b + "… and \(length - 10) more (fleet-doctor --json for the full report)" else empty end)' <<<"$r"
      fi
      j=$((j + 1))
    done
  else
    printf '\nDRIFT FINDINGS: none — no drifted repos.\n'
  fi
fi

# --- Explain narrative (--explain) --------------------------------------------

if $explain; then
  count=$(jq -r '.repos | length' <<<"$report")
  j=0
  while (( j < count )); do
    r=$(jq -c ".repos[$j] | select(.drift_report != null) // empty" <<<"$report")
    if [[ -n "$r" ]]; then
      printf '\n## %s\n\n' "$(jq -r '.name' <<<"$r")"
      score_arg=$(jq -r '.score // empty' <<<"$r")
      if [[ -n "$score_arg" ]]; then
        jq -c '.drift_report' <<<"$r" \
          | "${_script_dir}/explain-diff.sh" - --with-health "$score_arg" \
          || nyann::warn "explain-diff failed for $(jq -r '.name' <<<"$r")"
      else
        jq -c '.drift_report' <<<"$r" \
          | "${_script_dir}/explain-diff.sh" - \
          || nyann::warn "explain-diff failed for $(jq -r '.name' <<<"$r")"
      fi
    fi
    j=$((j + 1))
  done
fi

exit "$rc"
