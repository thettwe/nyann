#!/usr/bin/env bash
# coverage-tools/python.sh — emit total line-coverage % for a Python project.
#
# Applies when <target>/pyproject.toml or setup.cfg exists. PREFERS an
# existing coverage artifact:
#   1. coverage.xml (Cobertura, from `pytest --cov --cov-report=xml` or
#      `coverage xml`) — read the root <coverage> element's `line-rate`
#      (a 0..1 fraction) and scale ×100.
#   2. a cached `.coverage` data file via the `coverage` CLI — `coverage
#      report` only READS the cached data; it does not re-run the suite.
#
# Never runs the test suite. Soft-skips (exit non-zero, no output) when no
# artifact is present, so the guard stays cheap and non-blocking.
#
# Contract: print a bare percent and exit 0 when obtainable; else print
# nothing and exit non-zero.
target="${1:-$PWD}"

[[ -f "$target/pyproject.toml" || -f "$target/setup.cfg" ]] || exit 1

# 1. Cobertura coverage.xml — line-rate is a 0..1 fraction on the root
#    <coverage> element. Parsed with grep so no XML library is required.
xml="$target/coverage.xml"
if [[ -f "$xml" ]]; then
  rate=$(grep -o 'line-rate="[0-9.]*"' "$xml" 2>/dev/null | head -1 | sed 's/line-rate="//;s/"//')
  if [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    awk -v r="$rate" 'BEGIN{ printf "%.1f\n", r*100 }'
    exit 0
  fi
fi

# 2. Cached .coverage data file via the coverage CLI (reads cached data,
#    no re-run). The TOTAL row's last column is the percent.
if [[ -f "$target/.coverage" ]] && command -v coverage >/dev/null 2>&1; then
  pct=$( cd "$target" && coverage report 2>/dev/null \
           | awk '/^TOTAL/ { v=$NF; gsub("%","",v); print v; exit }' )
  if [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' "$pct"
    exit 0
  fi
fi

exit 1
