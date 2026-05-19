#!/usr/bin/env bash
# explain-diff.sh — translate a DriftReport JSON into plain-English markdown.
#
# Usage:
#   bin/explain-diff.sh --file <path>     [--format markdown|json]
#                                         [--with-health <0-100>]
#                                         [--with-trend  <signed-int>]
#   bin/doctor.sh ... | bin/explain-diff.sh -  [--format ...]
#
# Reads a DriftReport (schema: schemas/drift-report.schema.json) and
# emits either a human-readable markdown narrative (default) or a
# structured DriftNarrative JSON (schemas/drift-narrative.schema.json).
#
# The narrative is template-only — no LLM call. Severity → lead phrase
# mapping (matches the doctor renderer):
#   critical = "Action required"  (missing files, broken links, claude_md=error)
#   high     = "Worth fixing"     (misconfigured, claude_md=warn/absent)
#   medium   = "Drifted"          (orphans, stale docs, misplaced)
#   low      = "Minor"            (non-compliant history — informational)
#   info     = (suppressed in markdown; kept in JSON for downstream filtering)
#
# When --with-health / --with-trend are supplied, the header line embeds
# them. doctor.sh --explain pipes its computed health-score JSON in via
# these flags. Standalone callers can omit them; the schema's `health.score`
# is then null and the markdown skips the score line.
#
# Exit codes:
#   0 — narrative emitted (regardless of how many drift items the report had)
#   1 — bad input (missing file, malformed JSON, not a DriftReport shape)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# --- arg parsing -------------------------------------------------------------

file=""
format="markdown"
health_score=""
trend_delta=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)             file="${2:-}"; shift 2 ;;
    --file=*)           file="${1#--file=}"; shift ;;
    -)                  file="-"; shift ;;
    --format)           format="${2:-}"; shift 2 ;;
    --format=*)         format="${1#--format=}"; shift ;;
    --with-health)      health_score="${2:-}"; shift 2 ;;
    --with-health=*)    health_score="${1#--with-health=}"; shift ;;
    --with-trend)       trend_delta="${2:-}"; shift 2 ;;
    --with-trend=*)     trend_delta="${1#--with-trend=}"; shift ;;
    -h|--help)          sed -n '3,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$file" ]] || nyann::die "--file <path> (or - for stdin) is required"
case "$format" in
  markdown|json) ;;
  *) nyann::die "--format must be 'markdown' or 'json', got: $format" ;;
esac

# Validate optional numeric flags (don't trust caller-supplied values that
# end up embedded in printf/jq below).
if [[ -n "$health_score" ]]; then
  [[ "$health_score" =~ ^[0-9]+$ ]] || nyann::die "--with-health must be an integer 0-100, got: $health_score"
  (( health_score >= 0 && health_score <= 100 )) || nyann::die "--with-health must be in 0..100, got: $health_score"
fi
if [[ -n "$trend_delta" ]]; then
  [[ "$trend_delta" =~ ^-?[0-9]+$ ]] || nyann::die "--with-trend must be a signed integer, got: $trend_delta"
fi

# --- load report -------------------------------------------------------------

if [[ "$file" == "-" ]]; then
  report=$(cat)
else
  [[ -f "$file" ]] || nyann::die "DriftReport file not found: $file"
  report=$(cat "$file")
fi

# Smoke-test the shape: top-level required fields per
# schemas/drift-report.schema.json. Cheaper than full schema validation
# here, and matches the same one-line guard doctor.sh uses.
if ! jq -e 'type == "object"
  and has("target")
  and has("profile")
  and has("missing")
  and has("misconfigured")
  and has("documentation")
  and has("summary")' >/dev/null 2>&1 <<<"$report"; then
  nyann::die "input is not a DriftReport (top-level fields missing or shape mismatch)"
fi

# --- extract fields ----------------------------------------------------------

target=$(jq -r '.target' <<<"$report")
profile=$(jq -r '.profile' <<<"$report")

# Pull summary counts once; defaults match drift-report.schema.json's
# `required` list so missing optional fields don't break the read.
read -r n_missing n_mis n_off n_misplaced n_broken n_orphans n_stale n_subsys_errs claude_md_status < <(
  jq -r '[
    (.summary.missing // 0),
    (.summary.misconfigured // 0),
    (.summary.non_compliant_commits // 0),
    (.summary.misplaced // 0),
    (.summary.broken_links // 0),
    (.summary.orphans // 0),
    (.summary.stale_docs // 0),
    (.summary.subsystem_errors // 0),
    (.summary.claude_md_status // "ok")
  ] | @tsv' <<<"$report"
)

# Trend direction is derived; encode the "no prior session" case as "unknown"
# rather than synthesising a delta — the schema models this explicitly.
trend_dir="unknown"
if [[ -n "$trend_delta" ]]; then
  if (( trend_delta > 0 )); then
    trend_dir="up"
  elif (( trend_delta < 0 )); then
    trend_dir="down"
  else
    trend_dir="stable"
  fi
fi

# --- section builders --------------------------------------------------------
# Each builder appends one section JSON to $sections_json IF that
# category had at least one finding. We assemble the array first, then
# either emit it as JSON or render to markdown — both formats share the
# same source of truth.

sections_json='[]'

# nyann::eds_push <category> <severity> <count> <summary> <items_jq_expr>
#   Run <items_jq_expr> against the report to build the items[] string array,
#   then append a section object to $sections_json.
nyann::eds_push() {
  local category="$1" severity="$2" count="$3" summary="$4" items_expr="$5"
  local items_json
  items_json=$(jq -c "$items_expr" <<<"$report" 2>/dev/null || echo '[]')
  sections_json=$(jq --arg cat "$category" --arg sev "$severity" \
    --argjson cnt "$count" --arg sum "$summary" --argjson items "$items_json" \
    '. + [{category: $cat, severity: $sev, count: $cnt, summary: $sum, items: $items}]' \
    <<<"$sections_json")
}

# MISSING — top-level "the profile expected this and it's not here" set.
if (( n_missing > 0 )); then
  nyann::eds_push "hooks" "critical" "$n_missing" \
    "$n_missing required file(s) are missing — the profile expects them but they're not in the repo." \
    '[.missing[] | "Missing: " + .path + (if .detail then " (" + .detail + ")" else "" end)]'
fi

# MISCONFIGURED — profile expected a specific config; the file exists but its contents drift.
if (( n_mis > 0 )); then
  nyann::eds_push "github" "high" "$n_mis" \
    "$n_mis file(s) exist but differ from what the profile expects (drift, not absence)." \
    '[.misconfigured[] | "Drifted: " + .path + " — " + .reason +
       (if .missing_entries and (.missing_entries | length) > 0
        then " (missing entries: " + (.missing_entries | join(", ")) + ")"
        else "" end)]'
fi

# MISPLACED — docs found at non-canonical paths.
if (( ${n_misplaced:-0} > 0 )); then
  nyann::eds_push "misplaced" "medium" "$n_misplaced" \
    "$n_misplaced doc(s) live at non-canonical paths; nyann's reorganize-docs can move them." \
    '[.misplaced[] | "Misplaced: " + .source + " → " + .target +
       " (category: " + .category + ", confidence: " + (.confidence | tostring) + ")"]'
fi

# CLAUDE.md size — sub-section of documentation.
case "$claude_md_status" in
  error)
    bytes=$(jq -r '.documentation.claude_md.bytes' <<<"$report")
    hard=$(jq -r '.documentation.claude_md.hard_cap_bytes // 8192' <<<"$report")
    nyann::eds_push "claude_md" "critical" 1 \
      "CLAUDE.md is over the hard cap ($bytes B vs. $hard B) — extract content into linked docs." \
      '["CLAUDE.md exceeds the hard cap; move detail into docs/ files and link from CLAUDE.md instead"]'
    ;;
  warn)
    bytes=$(jq -r '.documentation.claude_md.bytes' <<<"$report")
    budget=$(jq -r '.documentation.claude_md.budget_bytes' <<<"$report")
    nyann::eds_push "claude_md" "high" 1 \
      "CLAUDE.md is over the soft budget ($bytes B vs. $budget B); consider trimming." \
      "[\"CLAUDE.md exceeds the soft budget — \`nyann:optimize-claudemd\` will analyse what to trim\"]"
    ;;
  absent)
    nyann::eds_push "claude_md" "high" 1 \
      "CLAUDE.md is missing — no router file present for AI agents to read." \
      "[\"No CLAUDE.md found; run \`nyann:gen-claudemd\` to scaffold one from the active profile\"]"
    ;;
esac

# BROKEN LINKS — critical if any are broken (an outright wrong link in docs).
if (( n_broken > 0 )); then
  nyann::eds_push "links" "critical" "$n_broken" \
    "$n_broken broken internal doc link(s) — references point at files that don't exist." \
    '[.documentation.links.broken[]? | "Broken link: " + .source + " → " + .link]'
fi

# ORPHANS — docs nobody references; medium severity (worth pruning).
if (( n_orphans > 0 )); then
  nyann::eds_push "orphans" "medium" "$n_orphans" \
    "$n_orphans orphan doc(s) — files in docs/ or memory/ that nothing else links to." \
    '[.documentation.orphans.orphans[]? |
       "Orphan: " + .path +
       (if .last_modified_days_ago then " (" + (.last_modified_days_ago | tostring) + " days old)" else "" end)]'
fi

# STALENESS — medium severity (a quality nudge).
if (( n_stale > 0 )); then
  threshold=$(jq -r '.documentation.staleness.threshold_days // 90' <<<"$report")
  nyann::eds_push "staleness" "medium" "$n_stale" \
    "$n_stale doc(s) past the staleness threshold ($threshold days) — review or refresh." \
    '[.documentation.staleness.stale[]? |
       "Stale: " + .path +
       (if .last_modified_days_ago then " (" + (.last_modified_days_ago | tostring) + " days)" else "" end)]'
fi

# NON-COMPLIANT HISTORY — informational; CC says we don't rewrite history.
if (( n_off > 0 )); then
  checked=$(jq -r '.non_compliant_history.checked // 0' <<<"$report")
  nyann::eds_push "history" "low" "$n_off" \
    "$n_off of the last $checked commit(s) don't follow Conventional Commits (informational — history rewrites are out of scope)." \
    '[.non_compliant_history.offenders[]? | "Non-CC: " + .sha + "  " + .subject]'
fi

# SUBSYSTEM ERRORS — never silent, even when the rest of the report is clean.
if (( n_subsys_errs > 0 )); then
  nyann::eds_push "documentation" "high" "$n_subsys_errs" \
    "$n_subsys_errs doc-check subsystem(s) failed to execute — the rest of this report may be incomplete." \
    '[.documentation.subsystem_errors[]? | "Subsystem error: " + .subsystem + " — " + .error]'
fi

# --- action items ------------------------------------------------------------
# Mirror the markdown "What you can do" bullets so a JSON consumer can
# render a checklist without re-parsing the prose. Order: most actionable
# first (retrofit covers the bulk).

action_items='[]'
if (( n_missing > 0 || n_mis > 0 )); then
  action_items=$(jq '. + ["Run `nyann:retrofit` — the missing/misconfigured set is what retrofit was built to fix."]' <<<"$action_items")
fi
if (( ${n_misplaced:-0} > 0 )); then
  action_items=$(jq '. + ["Run `nyann:retrofit` (it will offer to invoke reorganize-docs) to move the misplaced docs to canonical paths."]' <<<"$action_items")
fi
case "$claude_md_status" in
  warn|error)
    action_items=$(jq '. + ["Run `nyann:optimize-claudemd` to analyse CLAUDE.md content by reference frequency and trim what is unused."]' <<<"$action_items")
    ;;
  absent)
    action_items=$(jq '. + ["Run `nyann:gen-claudemd` to scaffold CLAUDE.md from the active profile."]' <<<"$action_items")
    ;;
esac
if (( n_broken > 0 )); then
  action_items=$(jq '. + ["Fix the broken internal doc links — they are likely renames the docs have not caught up to."]' <<<"$action_items")
fi
if (( n_orphans > 0 )); then
  action_items=$(jq '. + ["Decide whether the orphan docs should be linked from somewhere or deleted."]' <<<"$action_items")
fi
if (( n_stale > 0 )); then
  action_items=$(jq '. + ["Review the stale docs — either refresh them or raise the staleness threshold in your profile."]' <<<"$action_items")
fi
if (( n_subsys_errs > 0 )); then
  action_items=$(jq '. + ["Investigate the subsystem errors before trusting this report — re-run with NYANN_DEBUG=1 to surface stderr."]' <<<"$action_items")
fi

# --- assemble DriftNarrative JSON --------------------------------------------

scope_applied_json=$(jq -c '.scope_applied // []' <<<"$report")

# Optional fields use null sentinels rather than omitting from the object so
# the schema stays simple (no `oneOf required` gymnastics on consumers).
if [[ -n "$health_score" ]]; then
  health_score_json="$health_score"
else
  health_score_json="null"
fi
if [[ -n "$trend_delta" ]]; then
  trend_delta_json="$trend_delta"
else
  trend_delta_json="null"
fi

narrative=$(jq -n \
  --arg target "$target" \
  --arg profile "$profile" \
  --argjson scope "$scope_applied_json" \
  --argjson hscore "$health_score_json" \
  --argjson tdelta "$trend_delta_json" \
  --arg tdir "$trend_dir" \
  --argjson sections "$sections_json" \
  --argjson actions "$action_items" \
  '{
    target: $target,
    profile: $profile,
    scope_applied: (if ($scope | length) == 7 or ($scope | length) == 0 then null else $scope end),
    health: { score: $hscore, trend_delta: $tdelta, trend_direction: $tdir },
    sections: $sections,
    action_items: $actions
  } | with_entries(select(.value != null))')

# --- emit --------------------------------------------------------------------

if [[ "$format" == "json" ]]; then
  printf '%s\n' "$narrative" | jq '.'
  exit 0
fi

# Markdown rendering. Severity → lead-phrase mapping is duplicated from
# the comment block at the top of this file so a reader doesn't have to
# scroll. Keep the two in lockstep.
lead_for_severity() {
  case "$1" in
    critical) printf 'Action required:' ;;
    high)     printf 'Worth fixing:' ;;
    medium)   printf 'Drifted:' ;;
    low)      printf 'Minor:' ;;
    *)        printf '' ;;
  esac
}

{
  # shellcheck disable=SC2016
  # The backticks here are Markdown code-span delimiters, not shell
  # command substitution. Same reason `nyann:retrofit` is rendered in
  # backticks in every other emitted line — kept literal on purpose.
  printf '# Drift summary for `%s`\n\n' "$target"
  # shellcheck disable=SC2016
  printf 'Profile: `%s`' "$profile"
  scope_len=$(jq -r '.scope_applied | length' <<<"$narrative")
  if (( scope_len > 0 )); then
    scope_csv=$(jq -r '.scope_applied | join(", ")' <<<"$narrative")
    printf '  ·  Scope (partial): %s' "$scope_csv"
  fi
  printf '\n\n'

  if [[ -n "$health_score" ]]; then
    case "$trend_dir" in
      up)     printf 'Health score: **%s / 100** (↑ %s from last session — improvement).\n\n' "$health_score" "$trend_delta" ;;
      down)   printf 'Health score: **%s / 100** (↓ %s from last session — regression).\n\n' "$health_score" "${trend_delta#-}" ;;
      stable) printf 'Health score: **%s / 100** (→ stable since last session).\n\n' "$health_score" ;;
      *)      printf 'Health score: **%s / 100**.\n\n' "$health_score" ;;
    esac
  fi

  total_sections=$(jq -r '.sections | length' <<<"$narrative")
  if (( total_sections == 0 )); then
    printf '_No drift detected — nyann sees this repo as aligned with its profile._\n\n'
  else
    printf '## What'\''s drifted\n\n'
    # Iterate sections; bash `while read` consumes one section line at a time.
    # `sec_count` is intentionally read-but-unused: it's part of the
    # source DriftNarrative shape that consumers may want, but the
    # markdown render embeds the count in the summary prose itself.
    # Capturing it keeps the @tsv positions aligned so a future renderer
    # can use it without changing the jq invocation.
    # shellcheck disable=SC2034
    # sec_count is intentionally read-but-unused: it's part of the
    # source DriftNarrative shape that consumers may want, but the
    # markdown render embeds the count in the summary prose itself.
    # Capturing it keeps the @tsv positions aligned so a future renderer
    # can use it without changing the jq invocation.
    while IFS=$'\t' read -r sec_cat sec_sev sec_count sec_summary; do
      lead=$(lead_for_severity "$sec_sev")
      if [[ -z "$lead" ]]; then
        # info-tier sections are suppressed in markdown but stay in the JSON.
        continue
      fi
      printf -- '- **%s** %s %s\n' "$sec_cat" "$lead" "$sec_summary"
      # Indented item list (max 5 shown to keep the narrative paste-able);
      # if there are more, append a "...and N more" line so the reader
      # knows to consult the raw report.
      items_n=$(jq -r --arg cat "$sec_cat" '[.sections[] | select(.category == $cat) | .items[]] | length' <<<"$narrative")
      jq -r --arg cat "$sec_cat" '[.sections[] | select(.category == $cat) | .items[]][:5][] | "  - " + .' <<<"$narrative"
      if (( items_n > 5 )); then
        printf '  - …and %s more (see full report)\n' $((items_n - 5))
      fi
    done < <(jq -r '.sections[] | [.category, .severity, .count, .summary] | @tsv' <<<"$narrative")
    printf '\n'
  fi

  actions_n=$(jq -r '.action_items | length' <<<"$narrative")
  if (( actions_n > 0 )); then
    printf '## What you can do\n\n'
    jq -r '.action_items[] | "- " + .' <<<"$narrative"
    printf '\n'
  fi
}
