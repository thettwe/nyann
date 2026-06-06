#!/usr/bin/env bash
# docs-staleness.sh — flag docs whose correlated sources have churned since
# the doc was last updated.
#
# Usage:
#   docs-staleness.sh [--target <dir>] [--threshold-commits <n>] [--threshold-days <n>] [--profile <file>]
#
# Correlation heuristic (no LLM, no network):
#   docs/<topic>.md         → src/<topic>/** OR src/<topic>.{ts,js,py,go,rs}
#   docs/api-reference.md   → src/api/**, src/routes/**, src/handlers/**
#   docs/architecture.md    → src/** (broad; only flagged when very stale)
#   docs/runbook.md         → scripts/**, ops/**, infrastructure/**
#   docs/deployment.md      → .github/workflows/**, deploy/**, infrastructure/**
#
# A doc is "stale" when its correlated sources have been modified >= N
# commits OR the doc itself hasn't been touched in >= D days while at
# least one correlated source has changed. Profile thresholds:
#   documentation.staleness_threshold_commits (default: 5)
#   documentation.staleness_threshold_days    (default: 30)
#
# Emits DocsStalenessReport JSON on stdout. Exits 0 always (advisory).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
threshold_commits=5
threshold_days=30
profile_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)              target="${2-}"; shift 2 ;;
    --target=*)            target="${1#--target=}"; shift ;;
    --threshold-commits)   threshold_commits="${2-}"; shift 2 ;;
    --threshold-commits=*) threshold_commits="${1#--threshold-commits=}"; shift ;;
    --threshold-days)      threshold_days="${2-}"; shift 2 ;;
    --threshold-days=*)    threshold_days="${1#--threshold-days=}"; shift ;;
    --profile)             profile_file="${2-}"; shift 2 ;;
    --profile=*)           profile_file="${1#--profile=}"; shift ;;
    -h|--help)             sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
cd "$target" || nyann::die "cd $target failed"

# Pull thresholds from profile if provided.
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  v=$(jq -r '.documentation.staleness_threshold_commits // empty' "$profile_file" 2>/dev/null || true)
  [[ -n "$v" ]] && threshold_commits="$v"
  v=$(jq -r '.documentation.staleness_threshold_days // empty' "$profile_file" 2>/dev/null || true)
  [[ -n "$v" ]] && threshold_days="$v"
fi

# Require >= 1: a threshold of 0 would flag every doc and violates the
# schema (minimum: 1). Reject non-positive / non-numeric → fall back to default.
[[ "$threshold_commits" =~ ^[0-9]+$ ]] && (( threshold_commits >= 1 )) || threshold_commits=5
[[ "$threshold_days"    =~ ^[0-9]+$ ]] && (( threshold_days    >= 1 )) || threshold_days=30

# Quick exits: not a git repo, or no docs/ dir.
emit_empty() {
  jq -n \
    --arg t "$target" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson tc "$threshold_commits" \
    --argjson td "$threshold_days" \
    '{target:$t, scanned_at:$ts,
      thresholds:{commits:$tc, days:$td},
      summary:{stale_count:0, checked_count:0},
      findings:[]}'
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { emit_empty; exit 0; }
[[ -d docs ]] || { emit_empty; exit 0; }

# Resolve correlated source globs for a given doc path. Pure heuristic.
# Emit ONE path per line so callers can read into a bash array safely —
# this preserves paths containing spaces (e.g. `src/auth dir/`). The
# prior space-separated format relied on word-splitting and broke on
# any path with whitespace.
correlated_sources() {
  local doc="$1"
  case "$doc" in
    docs/api-reference.md)
      printf '%s\n' src/api src/routes src/handlers src/controllers
      ;;
    docs/architecture.md)
      printf '%s\n' src bin lib
      ;;
    docs/runbook.md)
      printf '%s\n' scripts ops infrastructure infra
      ;;
    docs/deployment.md)
      printf '%s\n' .github/workflows deploy infrastructure infra
      ;;
    docs/*.md)
      # topic-named docs → src/<topic>/** + src/<topic>.ext
      topic=$(basename "$doc" .md)
      printf '%s\n' "src/${topic}" "src/${topic}.ts" "src/${topic}.js" \
                    "src/${topic}.py" "src/${topic}.go" "src/${topic}.rs"
      ;;
    *)
      :
      ;;
  esac
}

now_ts=$(date +%s)
day_secs=86400

findings='[]'
checked=0

while IFS= read -r doc; do
  [[ -z "$doc" ]] && continue
  checked=$((checked + 1))
  # Last commit touching the doc.
  doc_last_ts=$(git log -1 --format=%ct -- "$doc" 2>/dev/null || echo 0)
  [[ "$doc_last_ts" -gt 0 ]] || continue
  doc_age_days=$(( (now_ts - doc_last_ts) / day_secs ))

  # Correlated source list — one path per line; read into a bash array so
  # paths with spaces survive intact through git log and jq construction.
  declare -a expanded=()
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    if [[ -d "$g" || -f "$g" ]]; then
      expanded+=("$g")
    fi
  done < <( correlated_sources "$doc" )
  (( ${#expanded[@]} == 0 )) && continue

  # Count commits touching correlated sources SINCE the doc was last touched.
  # `git log --since <unix-ts>` is non-portable; use --since="@<ts>".
  changes_since=$( git log --since="@$doc_last_ts" --pretty=format:%H -- "${expanded[@]}" 2>/dev/null | grep -c '.' || true )
  changes_since=${changes_since:-0}

  # Build the correlated_sources_sample JSON array from the bash array.
  sample=$(printf '%s\n' "${expanded[@]}" | jq -R . | jq -s '.')

  if (( changes_since >= threshold_commits )); then
    reason="$changes_since commits on correlated sources since doc last updated $doc_age_days days ago"
    findings=$(jq --arg doc "$doc" \
                   --argjson age "$doc_age_days" \
                   --argjson n "$changes_since" \
                   --arg reason "$reason" \
                   --argjson sample "$sample" \
                   '. + [{doc:$doc, last_doc_change_days:$age, source_changes_since:$n, correlated_sources_sample:$sample, reason:$reason}]' \
                   <<<"$findings")
    continue
  fi

  # Also stale if the doc is older than threshold_days AND at least one
  # correlated source changed in that window.
  if (( doc_age_days >= threshold_days )) && (( changes_since >= 1 )); then
    reason="doc untouched for $doc_age_days days while correlated sources changed $changes_since time(s)"
    findings=$(jq --arg doc "$doc" \
                   --argjson age "$doc_age_days" \
                   --argjson n "$changes_since" \
                   --arg reason "$reason" \
                   --argjson sample "$sample" \
                   '. + [{doc:$doc, last_doc_change_days:$age, source_changes_since:$n, correlated_sources_sample:$sample, reason:$reason}]' \
                   <<<"$findings")
  fi
done < <( find docs -type f -name '*.md' 2>/dev/null )

stale=$(jq 'length' <<<"$findings")

jq -n \
  --arg t "$target" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson tc "$threshold_commits" \
  --argjson td "$threshold_days" \
  --argjson stale "$stale" \
  --argjson checked "$checked" \
  --argjson findings "$findings" \
  '{target:$t, scanned_at:$ts,
    thresholds:{commits:$tc, days:$td},
    summary:{stale_count:$stale, checked_count:$checked},
    findings:$findings}'
