#!/usr/bin/env bash
# Guard: coverage-delta — warn (ADVISORY) when a branch lowers test
# coverage versus a cached baseline.
#
# OPT-IN. Off by default: it is NOT in any flow's builtin_guards list in
# pre-action-guard.sh. It runs only when a profile names it in
# `guards.pr` / `guards.ship`. Advisory by default (never silent-block);
# a profile promotes it to confirm/critical via the guards.<flow>[].severity
# lever that pre-action-guard already understands.
#
# Two modes, dispatched by whether $1 starts with `--`:
#
#   Guard mode (positional, invoked by pre-action-guard.sh):
#       coverage-delta.sh <target> <base> [<profile.json>]
#     <base> is part of the positional contract but unused (the baseline
#     file is the comparison point, not a git ref). Emits ONE GuardResult
#     fragment to stdout and ALWAYS exits 0 — exit codes 3/4 are
#     pre-action-guard's job, not the guard's.
#
#   Baseline-update mode (run on the base branch / post-merge):
#       coverage-delta.sh --update-baseline [--target <dir>]
#     Computes current coverage and writes
#     <target>/.nyann/coverage-baseline.json, then prints a confirmation.
#
# Coverage figures come from bin/coverage-tools/<stack>.sh — each prefers
# an existing CI artifact and soft-skips when none is present, so this
# guard never runs a slow suite and never blocks. The first stack tool
# (js, python, go, rust in that order) that yields a figure wins.

_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tools_dir="${_guard_dir}/../coverage-tools"

# detect_coverage <target>
#   Prints "<tool> <pct>" and returns 0 when a coverage figure is
#   obtainable from any stack tool; prints nothing and returns 1 otherwise.
detect_coverage() {
  local t="$1" tool script pct
  for tool in js python go rust; do
    script="${tools_dir}/${tool}.sh"
    [[ -f "$script" ]] || continue
    if pct=$(bash "$script" "$t" 2>/dev/null) && [[ -n "$pct" ]]; then
      printf '%s %s\n' "$tool" "$pct"
      return 0
    fi
  done
  return 1
}

# write_baseline <target> <tool> <pct>
#   Writes <target>/.nyann/coverage-baseline.json (schema:
#   coverage-baseline.schema.json). Returns non-zero if it cannot write.
write_baseline() {
  local t="$1" tool="$2" pct="$3" dir file ts commit tmp
  dir="$t/.nyann"
  file="$dir/coverage-baseline.json"
  [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  # Bound to the schema's 0–100 range so a corrupt artifact (e.g. a cobertura
  # line-rate="1.5" → 150) can't write a baseline that fails
  # coverage-baseline.schema.json (maximum:100).
  LC_ALL=C awk -v v="$pct" 'BEGIN{exit !(v>=0 && v<=100)}' || return 1
  # The baseline path is predictable; refuse to follow a pre-planted symlink
  # at the dir or the file, so a hostile repo can't redirect the write out of
  # tree. Then write to a temp file in $dir and mv into place (atomic, and
  # `mv` replaces a symlink target rather than following it).
  [[ -L "$dir" || -L "$file" ]] && return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  commit=$(git -C "$t" rev-parse HEAD 2>/dev/null || echo "")
  tmp=$(mktemp "$dir/coverage-baseline.json.XXXXXX") || return 1
  if [[ -n "$commit" ]]; then
    jq -n --arg tool "$tool" --argjson pct "$pct" --arg ts "$ts" --arg commit "$commit" \
      '{tool:$tool, coverage_pct:$pct, recorded_at:$ts, commit:$commit}' \
      > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    jq -n --arg tool "$tool" --argjson pct "$pct" --arg ts "$ts" \
      '{tool:$tool, coverage_pct:$pct, recorded_at:$ts}' \
      > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# emit <pass:true|false> <message> [<skipped:true>]
#   Print one GuardResult fragment matching schemas/guard-result.schema.json
#   guards[] items. Always advisory; pre-action-guard promotes if asked.
emit() {
  local pass="$1" message="$2" skipped="${3-}"
  if [[ -n "$skipped" ]]; then
    jq -n --arg name "coverage-delta" --argjson pass "$pass" --arg msg "$message" \
      '{name:$name, pass:$pass, severity:"advisory", skipped:true, message:$msg}'
  else
    jq -n --arg name "coverage-delta" --argjson pass "$pass" --arg msg "$message" \
      '{name:$name, pass:$pass, severity:"advisory", message:$msg}'
  fi
}

# --- Baseline-update mode ----------------------------------------------------
if [[ "${1-}" == --* ]]; then
  target="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --update-baseline) shift ;;
      --target)   target="${2-}"; shift; [[ $# -gt 0 ]] && shift ;;
      --target=*) target="${1#--target=}"; shift ;;
      -h|--help)  sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) shift ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    printf 'coverage-delta: jq is required for --update-baseline\n' >&2
    exit 1
  fi
  [[ -d "$target" ]] || { printf 'coverage-delta: not a directory: %s\n' "$target" >&2; exit 1; }

  if ! detected=$(detect_coverage "$target"); then
    printf 'coverage-delta: no coverage tool/artifact under %s — nothing to record\n' "$target" >&2
    exit 1
  fi
  tool="${detected%% *}"; current="${detected#* }"
  if write_baseline "$target" "$tool" "$current"; then
    printf 'coverage-delta: recorded baseline %s=%s%% → %s/.nyann/coverage-baseline.json\n' \
      "$tool" "$current" "$target"
    exit 0
  fi
  printf 'coverage-delta: failed to write baseline under %s\n' "$target" >&2
  exit 1
fi

# --- Guard mode (positional) -------------------------------------------------
target="${1:-$PWD}"
# $2 (base) intentionally unused — the baseline file is the comparison point.
profile_file="${3-}"

# jq absent → degrade to a hand-built skip fragment (no message chars need
# escaping) and exit 0. NEVER hard-fail in guard mode.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"name":"coverage-delta","pass":true,"severity":"advisory","skipped":true,"message":"jq unavailable — skipped"}'
  exit 0
fi

# awk drives the float comparison below. If it is absent the verdict would be
# empty and fall through to a FALSE "coverage dropped" — which a promoted
# profile could turn into a real block. Soft-skip instead (never-block).
if ! command -v awk >/dev/null 2>&1; then
  emit true "awk unavailable — skipped" true
  exit 0
fi

# Detect the applicable stack + current coverage. No tool/artifact → skip.
if ! detected=$(detect_coverage "$target"); then
  emit true "no coverage tool/artifact — skipped" true
  exit 0
fi
tool="${detected%% *}"; current="${detected#* }"
if [[ ! "$current" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  emit true "coverage figure unparseable — skipped" true
  exit 0
fi
# A corrupt artifact can yield an out-of-range figure (e.g. line-rate>1 → >100);
# soft-skip rather than record/compare a nonsense baseline.
if ! LC_ALL=C awk -v v="$current" 'BEGIN{exit !(v>=0 && v<=100)}'; then
  emit true "coverage figure out of range (${current}) — skipped" true
  exit 0
fi

baseline_file="$target/.nyann/coverage-baseline.json"

# Missing baseline → record it and pass (first run establishes the floor).
if [[ ! -f "$baseline_file" ]]; then
  if write_baseline "$target" "$tool" "$current"; then
    emit true "coverage baseline recorded ($tool ${current}%)"
  else
    emit true "coverage ${current}% — baseline could not be written, skipped" true
  fi
  exit 0
fi

# Read + defensively validate the baseline (schema-shape: numeric
# coverage_pct). A malformed baseline soft-skips rather than false-warning.
baseline=$(jq -r '.coverage_pct // empty' "$baseline_file" 2>/dev/null || true)
if [[ ! "$baseline" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  emit true "coverage baseline malformed — skipped" true
  exit 0
fi
# Range-gate the persisted baseline too (symmetry with the current-figure
# check): an externally corrupted/hand-edited out-of-[0,100] baseline must
# soft-skip, never produce a false "dropped" advisory.
if ! LC_ALL=C awk -v v="$baseline" 'BEGIN{exit !(v>=0 && v<=100)}'; then
  emit true "coverage baseline out of range (${baseline}) — skipped" true
  exit 0
fi

# Stack-identity guard: in a polyglot repo detect_coverage (first-wins) may
# pick a different stack than the one the baseline was recorded for (artifact
# presence varies between record-time and run-time). Comparing a JS figure
# against a Go baseline is meaningless — skip rather than false-warn.
baseline_tool=$(jq -r '.tool // empty' "$baseline_file" 2>/dev/null || true)
if [[ -n "$baseline_tool" && "$baseline_tool" != "$tool" ]]; then
  emit true "baseline tool ($baseline_tool) != detected ($tool) — skipped" true
  exit 0
fi

# Allowed drop from the profile (percentage points). Default 0 = any drop warns.
threshold=0
if [[ -n "$profile_file" && -f "$profile_file" ]]; then
  threshold=$(jq -r '.guards.coverage_delta_threshold // 0' "$profile_file" 2>/dev/null || echo 0)
fi
[[ "$threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || threshold=0

# Compare with awk (float-safe): pass when current >= baseline - threshold.
# LC_ALL=C so a comma-decimal locale neither breaks the compare nor prints a
# `Δ-2,6` in the user-facing message.
verdict=$(LC_ALL=C awk -v c="$current" -v b="$baseline" -v t="$threshold" \
  'BEGIN{ if (c >= b - t) print "pass"; else print "fail" }')
delta=$(LC_ALL=C awk -v c="$current" -v b="$baseline" 'BEGIN{ printf "%+.1f", c - b }')

# Only a clean pass/fail is trustworthy. Any other verdict (awk errored) is a
# skip, NOT a false "dropped" — that would be a phantom drop a promoted
# profile could escalate to a block.
if [[ "$verdict" == "pass" ]]; then
  emit true "coverage ${baseline}% → ${current}% (Δ${delta}, threshold ${threshold})"
elif [[ "$verdict" == "fail" ]]; then
  emit false "coverage dropped ${baseline}% → ${current}% (Δ${delta}, threshold ${threshold})"
else
  emit true "coverage compare failed — skipped" true
fi
exit 0
