#!/usr/bin/env bash
# coverage-tools/rust.sh — emit total line-coverage % for a Rust project.
#
# Applies when <target>/Cargo.toml exists. PREFERS an existing
# cargo-tarpaulin artifact:
#   1. cobertura.xml (`cargo tarpaulin --out Xml`) — root <coverage>
#      `line-rate` (0..1) scaled ×100.
#   2. tarpaulin-report.json (`cargo tarpaulin --out Json`) — top-level
#      `.coverage` percent, when present.
#
# Never runs tarpaulin (slow, recompiles). Soft-skips (exit non-zero, no
# output) when no artifact is present.
#
# Contract: print a bare percent and exit 0 when obtainable; else print
# nothing and exit non-zero.
target="${1:-$PWD}"

[[ -f "$target/Cargo.toml" ]] || exit 1

# 1. Cobertura XML — grep the root line-rate (no XML library needed).
for xml in cobertura.xml tarpaulin-cobertura.xml; do
  if [[ -f "$target/$xml" ]]; then
    rate=$(grep -o 'line-rate="[0-9.]*"' "$target/$xml" 2>/dev/null | head -1 | sed 's/line-rate="//;s/"//')
    if [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      # LC_ALL=C so a comma-decimal locale can't emit `65,3` and fail the
      # guard's numeric regex (silently disabling the Rust stack).
      LC_ALL=C awk -v r="$rate" 'BEGIN{ printf "%.1f\n", r*100 }'
      exit 0
    fi
  fi
done

# 2. tarpaulin JSON report exposing a top-level percent.
if [[ -f "$target/tarpaulin-report.json" ]] && command -v jq >/dev/null 2>&1; then
  pct=$(jq -r '.coverage // empty' "$target/tarpaulin-report.json" 2>/dev/null || true)
  if [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' "$pct"
    exit 0
  fi
fi

exit 1
