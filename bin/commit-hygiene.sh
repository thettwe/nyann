#!/usr/bin/env bash
# commit-hygiene.sh — pre-commit analysis of the staged diff.
#
# Usage:
#   commit-hygiene.sh [--target <dir>] [--profile <file>] [--patterns <csv>]
#
# Emits CommitHygieneReport JSON on stdout. Three checks:
#   1. Scope suggestion from staged paths (first top-level segment).
#   2. Incomplete staging: source<->test pairings, lockfile drift.
#   3. Debug artifacts: configurable regex scan over the staged diff.
#
# Pairs with bin/dead-code-scan.sh — its findings are folded in under
# .dead_code for downstream consumers.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_file=""
patterns_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --profile)    profile_file="${2-}"; shift 2 ;;
    --profile=*)  profile_file="${1#--profile=}"; shift ;;
    --patterns)   patterns_override="${2-}"; shift 2 ;;
    --patterns=*) patterns_override="${1#--patterns=}"; shift ;;
    -h|--help)    sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target is not a directory: $target"
cd "$target" || nyann::die "cd $target failed"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  jq -n --arg t "$target" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    target:$t, scanned_at:$ts,
    summary:{warnings:0, advisories:0},
    scope_suggestion:{scopes:[], primary:null},
    incomplete_staging:[], debug_artifacts:[], dead_code:[]
  }'
  exit 0
fi

# --- 1. Scope suggestion -----------------------------------------------------
# Heuristic: top-level segment of each staged file (modules/, src/, etc.).
# When all staged paths agree on the same segment, that's the primary.
# Workspaces in monorepos use the first non-trivial directory.
staged_files=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMRD 2>/dev/null || true)
scopes_raw=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  seg=$(printf '%s' "$f" | awk -F/ '{print $1}')
  # Skip non-informative top segments.
  case "$seg" in
    .|..|"") continue ;;
  esac
  scopes_raw+="$seg"$'\n'
done <<< "$staged_files"
scopes_unique=$(printf '%s' "$scopes_raw" | sort -u | grep -v '^$' || true)
scopes_json=$(printf '%s\n' "$scopes_unique" | jq -R . | jq -s 'map(select(length > 0))')
n_scopes=$(jq 'length' <<<"$scopes_json")
if [[ "$n_scopes" -eq 1 ]]; then
  primary=$(jq -r '.[0]' <<<"$scopes_json")
  primary_json=$(jq -n --arg p "$primary" '$p')
else
  primary_json='null'
fi
scope_suggestion=$(jq -n --argjson scopes "$scopes_json" --argjson primary "$primary_json" \
  '{scopes:$scopes, primary:$primary}')

# --- 2. Incomplete staging ---------------------------------------------------
# Source<->test pairings and lockfile drift. Pure heuristic.
modified_unstaged=$(git -c core.quotePath=false diff --name-only 2>/dev/null || true)

incomplete='[]'
add_incomplete() {
  local staged="$1" missing="$2" reason="$3"
  incomplete=$(jq --arg s "$staged" --arg m "$missing" --arg r "$reason" \
    '. + [{staged:$s, missing:$m, reason:$r}]' <<<"$incomplete")
}

is_modified_unstaged() {
  grep -Fqx "$1" <<<"$modified_unstaged"
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Resolve sibling paths relative to the manifest's own directory so
  # monorepo workspace manifests (packages/app/package.json) pair with
  # their adjacent lockfile, not the repo-root one.
  fdir="$(dirname "$f")"
  sib() { if [[ "$fdir" == "." ]]; then printf '%s' "$1"; else printf '%s/%s' "$fdir" "$1"; fi; }
  case "${f##*/}" in
    package.json)
      if is_modified_unstaged "$(sib package-lock.json)" || is_modified_unstaged "$(sib pnpm-lock.yaml)" || is_modified_unstaged "$(sib yarn.lock)"; then
        add_incomplete "$f" "lockfile" "package.json staged but lockfile is modified-but-unstaged"
      fi
      ;;
    package-lock.json|pnpm-lock.yaml|yarn.lock)
      if is_modified_unstaged "$(sib package.json)"; then
        add_incomplete "$f" "package.json" "lockfile staged but package.json is modified-but-unstaged"
      fi
      ;;
    *.py)
      # Test file siblings.
      stem="${f%.py}"
      base="$(basename "$stem")"
      dir="$(dirname "$f")"
      test_a="${dir}/test_${base}.py"
      test_b="tests/test_${base}.py"
      if [[ "$f" != test_* && "$base" != test_* ]]; then
        for t in "$test_a" "$test_b"; do
          if is_modified_unstaged "$t"; then
            add_incomplete "$f" "$t" "source staged but matching test is modified-but-unstaged"
          fi
        done
      fi
      ;;
    *.ts|*.tsx|*.js|*.jsx)
      stem="${f%.*}"
      ext="${f##*.}"
      test_a="${stem}.test.${ext}"
      test_b="${stem}.spec.${ext}"
      if [[ "$f" != *.test.* && "$f" != *.spec.* ]]; then
        for t in "$test_a" "$test_b"; do
          if is_modified_unstaged "$t"; then
            add_incomplete "$f" "$t" "source staged but matching test is modified-but-unstaged"
          fi
        done
      fi
      ;;
  esac
done <<< "$staged_files"

# --- 3. Debug artifact scan --------------------------------------------------
# Patterns: explicit --patterns CSV > profile.conventions.commit_hygiene_patterns > defaults.
# Use POSIX ERE — escape `(` and avoid trailing-semicolon syntax issues on
# BSD awk by anchoring on the keyword only.
default_patterns='console\.log|debugger|print\(|TODO|FIXME|XXX'
patterns="$default_patterns"
if [[ -n "$patterns_override" ]]; then
  patterns=$(printf '%s' "$patterns_override" | tr ',' '|')
elif [[ -n "$profile_file" && -f "$profile_file" ]]; then
  prof_pats=$(jq -r '(.conventions.commit_hygiene_patterns // []) | join("|")' "$profile_file" 2>/dev/null || true)
  [[ -n "$prof_pats" ]] && patterns="$prof_pats"
fi

debug_artifacts='[]'
artifacts_tmp=$(mktemp -t nyann-artifacts.XXXXXX)
trap 'rm -f "$artifacts_tmp"' EXIT
: > "$artifacts_tmp"

# Walk the staged diff hunk-by-hunk in pure bash so we can track destination
# line numbers, then grep each added line for the pattern. Keeps the regex
# engine to grep -E (POSIX ERE) which is consistent across BSD/GNU.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$f" ]] || continue
  line=0
  in_hunk=0
  while IFS= read -r dline; do
    # The diff file header (`--- a/..`, `+++ b/..`) only appears before the
    # first `@@` hunk. After a hunk has started, a line beginning `+++ ` or
    # `--- ` is genuine added/removed content (e.g. `+++ marker`), not a
    # header — so only skip header lines while in_hunk is still 0.
    if (( ! in_hunk )); then
      case "$dline" in
        '+++ '*|'--- '*) continue ;;
      esac
    fi
    case "$dline" in
      '@@ '*)
        # Hunk header `@@ -a,b +c,d @@` — seed line counter at c - 1.
        plus=${dline#*+}
        plus=${plus%% *}
        start=${plus%%,*}
        line=$((start - 1))
        in_hunk=1
        continue
        ;;
      '+'*)
        line=$((line + 1))
        body=${dline#+}
        if printf '%s' "$body" | grep -qE -- "$patterns"; then
          match=$(printf '%s' "$body" | grep -oE -- "$patterns" | head -1)
          # Build the finding via `jq -n --arg` so filenames containing
          # double-quotes or backslashes produce well-formed JSON. Raw
          # printf would corrupt the per-line NDJSON and the subsequent
          # `jq -s` aggregation would error on the whole batch.
          jq -nc \
            --arg file "$f" \
            --argjson line "$line" \
            --arg pat "$patterns" \
            --arg match "$match" \
            '{file:$file, line:$line, pattern:$pat, match:$match}' \
            >> "$artifacts_tmp"
        fi
        ;;
      '-'*) continue ;;
      ' '*) line=$((line + 1)) ;;
    esac
  done < <( git diff --cached --no-color -U0 -- "$f" 2>/dev/null )
done <<< "$staged_files"

if [[ -s "$artifacts_tmp" ]]; then
  debug_artifacts=$(jq -s '.' < "$artifacts_tmp")
fi

# --- 4. Dead code (delegated to bin/dead-code-scan.sh) -----------------------
dead_code='[]'
if [[ -x "${_script_dir}/dead-code-scan.sh" || -f "${_script_dir}/dead-code-scan.sh" ]]; then
  # If profile has conventions.dead_code_scan == false, skip.
  enabled=true
  if [[ -n "$profile_file" && -f "$profile_file" ]]; then
    flag=$(jq -r '.conventions.dead_code_scan // empty' "$profile_file" 2>/dev/null || true)
    [[ "$flag" == "false" ]] && enabled=false
  fi
  if $enabled; then
    if dcs=$(bash "${_script_dir}/dead-code-scan.sh" --target "$target" 2>/dev/null); then
      dead_code=$(jq '.findings // []' <<<"$dcs")
    fi
  fi
fi

# --- Assemble report ---------------------------------------------------------
warnings=0
warnings=$(( warnings + $(jq 'length' <<<"$incomplete") ))
warnings=$(( warnings + $(jq 'length' <<<"$debug_artifacts") ))
warnings=$(( warnings + $(jq 'length' <<<"$dead_code") ))
advisories=0
[[ "$n_scopes" -gt 1 ]] && advisories=1

jq -n \
  --arg t "$target" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson scope_suggestion "$scope_suggestion" \
  --argjson incomplete_staging "$incomplete" \
  --argjson debug_artifacts "$debug_artifacts" \
  --argjson dead_code "$dead_code" \
  --argjson warnings "$warnings" \
  --argjson advisories "$advisories" \
  '{target:$t, scanned_at:$ts,
    summary:{warnings:$warnings, advisories:$advisories},
    scope_suggestion:$scope_suggestion,
    incomplete_staging:$incomplete_staging,
    debug_artifacts:$debug_artifacts,
    dead_code:$dead_code}'
