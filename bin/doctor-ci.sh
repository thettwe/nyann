#!/usr/bin/env bash
# doctor-ci.sh — CI-native governance gate: run drift checks, score health,
# emit GitHub Actions annotations, and generate a PR comment body.
#
# Usage:
#   doctor-ci.sh --target <repo> --profile <path>
#                [--threshold <0-100>]       # default: 70
#                [--severity block|warn|off]  # default: block
#                [--ignore <category>,...]    # comma-separated categories to skip
#                [--comment-file <path>]      # write PR comment markdown here
#                [--annotations]              # emit GitHub Actions annotations to stdout
#
# Runs compute-drift.sh → compute-health-score.sh, then:
#   - Computes a (possibly filtered) governance score
#   - Emits GitHub Actions ::error:: / ::warning:: annotations (--annotations)
#   - Writes a PR comment markdown body (--comment-file)
#   - Outputs JSON result to stdout
#
# Exit codes:
#   0 — gate passed (score >= threshold, or severity is warn/off)
#   1 — gate failed (score < threshold and severity is block)
#   2 — hard error (bad arguments, not a git repo, etc.)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
threshold=70
severity="block"
ignore_csv=""
comment_file=""
annotations=false
threshold_set=false
severity_set=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --profile)       profile_path="${2:-}"; shift 2 ;;
    --profile=*)     profile_path="${1#--profile=}"; shift ;;
    --threshold)     threshold="${2:-70}"; threshold_set=true; shift 2 ;;
    --threshold=*)   threshold="${1#--threshold=}"; threshold_set=true; shift ;;
    --severity)      severity="${2:-block}"; severity_set=true; shift 2 ;;
    --severity=*)    severity="${1#--severity=}"; severity_set=true; shift ;;
    --ignore)        ignore_csv="${2:-}"; shift 2 ;;
    --ignore=*)      ignore_csv="${1#--ignore=}"; shift ;;
    --comment-file)  comment_file="${2:-}"; shift 2 ;;
    --comment-file=*) comment_file="${1#--comment-file=}"; shift ;;
    --annotations)   annotations=true; shift ;;
    -h|--help)       sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- validate inputs ---------------------------------------------------------

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

[[ -f "$profile_path" ]] || nyann::die "--profile <path> is required and must exist"

[[ "$threshold" =~ ^[0-9]+$ && "$threshold" -ge 0 && "$threshold" -le 100 ]] \
  || nyann::die "--threshold must be an integer 0-100"

case "$severity" in
  block|warn|off) ;;
  *) nyann::die "--severity must be block|warn|off" ;;
esac

# Parse governance config from profile (overrides CLI defaults when present).
gov_json=$(jq -r '.governance // {}' "$profile_path" 2>/dev/null || echo '{}')
if [[ "$gov_json" != "{}" ]]; then
  prof_threshold=$(jq -r '.threshold // empty' <<<"$gov_json" 2>/dev/null || true)
  prof_severity=$(jq -r '.severity // empty' <<<"$gov_json" 2>/dev/null || true)
  prof_ignore=$(jq -r '.ignore // [] | join(",")' <<<"$gov_json" 2>/dev/null || true)
  # CLI flags override profile values (explicit > config).
  if [[ -n "$prof_threshold" ]] && ! $threshold_set; then
    if [[ "$prof_threshold" =~ ^[0-9]+$ ]] && (( prof_threshold >= 0 && prof_threshold <= 100 )); then
      threshold="$prof_threshold"
    else
      nyann::warn "profile governance.threshold invalid ($prof_threshold), using CLI default"
    fi
  fi
  if [[ -n "$prof_severity" ]] && ! $severity_set; then
    case "$prof_severity" in
      block|warn|off) severity="$prof_severity" ;;
      *) nyann::warn "profile governance.severity invalid ($prof_severity), using CLI default" ;;
    esac
  fi
  [[ -n "$prof_ignore" && -z "$ignore_csv" ]] && ignore_csv="$prof_ignore"
fi

if [[ "$severity" == "off" ]]; then
  jq -n '{status:"skipped", reason:"governance severity is off"}'
  exit 0
fi

# --- run drift + health score ------------------------------------------------

drift_json=$("${_script_dir}/compute-drift.sh" --target "$target" --profile "$profile_path" 2>/dev/null) \
  || nyann::die "compute-drift.sh failed"

health_json=$(echo "$drift_json" | "${_script_dir}/compute-health-score.sh" 2>/dev/null) \
  || nyann::die "compute-health-score.sh failed"

raw_score=$(jq -r '.score' <<<"$health_json")
breakdown_json=$(jq '.breakdown' <<<"$health_json")
max_deductions_json=$(jq '.max_deductions' <<<"$health_json")

# --- apply ignore filter -----------------------------------------------------
# Zero out deductions for ignored categories so they don't affect the gate.

filtered_score="$raw_score"
if [[ -n "$ignore_csv" ]]; then
  IFS=',' read -ra ignore_arr <<< "$ignore_csv"
  for cat in "${ignore_arr[@]}"; do
    cat=$(printf '%s' "$cat" | tr -d '[:space:]')
    ded=$(jq -r --arg c "$cat" '.[$c] // 0' <<<"$breakdown_json")
    if [[ "$ded" =~ ^-?[0-9]+$ ]]; then
      # Deductions are negative, so subtracting them adds back the points.
      filtered_score=$((filtered_score - ded))
    fi
  done
  # Clamp to 0-100.
  (( filtered_score > 100 )) && filtered_score=100
  (( filtered_score < 0 )) && filtered_score=0
fi

# --- determine gate outcome --------------------------------------------------

status="pass"
gate_passed=true
if (( filtered_score < threshold )); then
  if [[ "$severity" == "warn" ]]; then
    status="warn"
  else
    status="fail"
    gate_passed=false
  fi
fi

# --- GitHub Actions annotations ----------------------------------------------

annotation_count=0

emit_annotations() {
  local level="$1" category="$2" items_json="$3" msg_template="$4"
  local count
  count=$(jq 'length' <<<"$items_json")
  (( count == 0 )) && return 0

  # Skip ignored categories.
  if [[ -n "$ignore_csv" ]]; then
    IFS=',' read -ra iarr <<< "$ignore_csv"
    for ic in "${iarr[@]}"; do
      ic=$(printf '%s' "$ic" | tr -d '[:space:]')
      [[ "$ic" == "$category" ]] && return 0
    done
  fi

  local i
  for (( i=0; i < count && i < 10; i++ )); do
    local msg
    msg=$(jq -r --argjson idx "$i" "$msg_template" <<<"$items_json")
    printf '::%s title=nyann governance (%s)::%s\n' "$level" "$category" "$msg" >&2
    annotation_count=$((annotation_count + 1))
  done
  if (( count > 10 )); then
    printf '::%s title=nyann governance (%s)::...and %d more\n' "$level" "$category" "$((count - 10))" >&2
    annotation_count=$((annotation_count + 1))
  fi
}

# shellcheck disable=SC2016  # jq templates, not shell expansions
if $annotations; then
  missing_json=$(jq '.missing // []' <<<"$drift_json")
  emit_annotations "error" "missing" "$missing_json" \
    '.[$idx] | "Missing \(.kind): \(.path)"'

  misconf_json=$(jq '.misconfigured // []' <<<"$drift_json")
  emit_annotations "warning" "misconfigured" "$misconf_json" \
    '.[$idx] | "Misconfigured: \(.path) — \(.reason)"'

  offenders_json=$(jq '.non_compliant_history.offenders // []' <<<"$drift_json")
  emit_annotations "warning" "non_compliant" "$offenders_json" \
    '.[$idx] | "Non-conventional commit: \(.sha[0:7]) \(.subject)"'

  broken_json=$(jq '.documentation.links.broken // []' <<<"$drift_json")
  emit_annotations "warning" "broken_links" "$broken_json" \
    '.[$idx] | "Broken link: \(.source) → \(.target)"'
fi

# --- PR comment body ---------------------------------------------------------

grade() {
  local s=$1
  if   (( s >= 90 )); then echo "A+"
  elif (( s >= 80 )); then echo "A"
  elif (( s >= 70 )); then echo "B"
  elif (( s >= 60 )); then echo "C"
  elif (( s >= 50 )); then echo "D"
  else echo "F"
  fi
}

generate_comment() {
  local g
  g=$(grade "$filtered_score")

  local icon="✅"
  [[ "$status" == "warn" ]] && icon="⚠️"
  [[ "$status" == "fail" ]] && icon="❌"

  cat <<COMMENT
## ${icon} nyann governance — ${g} (${filtered_score}/100)

| Category | Deduction | Items |
|----------|-----------|-------|
COMMENT

  local cats=(missing misconfigured non_compliant broken_links claude_md orphans stale subsystem_errors)
  for c in "${cats[@]}"; do
    local ded items
    ded=$(jq -r --arg c "$c" '.[$c] // 0' <<<"$breakdown_json")
    items=$(jq -r --arg c "$c" '.[$c] // 0' <<<"$max_deductions_json")
    if [[ "$ded" != "0" && "$ded" != "-0" ]]; then
      printf '| %s | %s | %s |\n' "$c" "$ded" "$items"
    fi
  done

  if [[ -n "$ignore_csv" ]]; then
    printf '\n*Ignored categories: %s (raw score: %d)*\n' "$ignore_csv" "$raw_score"
  fi

  printf '\n**Threshold:** %d | **Severity:** %s | **Result:** %s\n' \
    "$threshold" "$severity" "$status"

  if [[ "$status" == "fail" ]]; then
    # shellcheck disable=SC2016
    printf '\n> Run `/nyann:doctor` locally to see full details and `/nyann:retrofit` to fix drift.\n'
  fi
}

comment_body=$(generate_comment)

if [[ -n "$comment_file" ]]; then
  [[ -L "$comment_file" ]] && nyann::die "refusing to write comment via symlink: $comment_file"
  printf '%s\n' "$comment_body" > "$comment_file"
fi

# --- JSON output -------------------------------------------------------------

jq -n \
  --arg status "$status" \
  --argjson score "$filtered_score" \
  --argjson raw_score "$raw_score" \
  --argjson threshold "$threshold" \
  --arg severity "$severity" \
  --argjson annotation_count "$annotation_count" \
  --argjson breakdown "$breakdown_json" \
  --argjson max_deductions "$max_deductions_json" \
  --arg ignore "${ignore_csv}" \
  '{status:$status, score:$score, raw_score:$raw_score,
    threshold:$threshold, severity:$severity,
    annotation_count:$annotation_count,
    breakdown:$breakdown, max_deductions:$max_deductions,
    ignored_categories:(if $ignore == "" then [] else ($ignore | split(",") | map(gsub("^\\s+|\\s+$"; ""))) end)}'

if ! $gate_passed; then
  exit 1
fi
