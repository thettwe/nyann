#!/usr/bin/env bash
# coverage-tools/python.sh — emit total line-coverage % for a Python project.
#
# Applies when <target>/pyproject.toml or setup.cfg exists. Reads ONLY a
# static coverage artifact:
#   coverage.xml (Cobertura, from `pytest --cov --cov-report=xml` or
#   `coverage xml`) — read the root <coverage> element's `line-rate`
#   (a 0..1 fraction) and scale ×100.
#
# It NEVER runs a subprocess that imports repo code. In particular it does
# NOT shell out to `coverage report`, which constructs a Coverage object
# that auto-loads the repo's .coveragerc / setup.cfg / pyproject.toml
# `[tool.coverage.run] plugins = …` and IMPORTS them — arbitrary code
# execution from the branch under review. Like js.sh / rust.sh / go.sh, this
# parser only reads a static file. Soft-skips (exit non-zero, no output)
# when no coverage.xml is present, so the guard stays cheap and non-blocking.
#
# Contract: print a bare percent and exit 0 when obtainable; else print
# nothing and exit non-zero.
target="${1:-$PWD}"

[[ -f "$target/pyproject.toml" || -f "$target/setup.cfg" ]] || exit 1

# Cobertura coverage.xml — line-rate is a 0..1 fraction on the root
# <coverage> element. Parsed with grep so no XML library is required.
xml="$target/coverage.xml"
if [[ -f "$xml" ]]; then
  rate=$(grep -o 'line-rate="[0-9.]*"' "$xml" 2>/dev/null | head -1 | sed 's/line-rate="//;s/"//')
  if [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # LC_ALL=C so a comma-decimal locale can't emit `91,2` and fail the
    # guard's numeric regex (silently disabling the Python stack).
    LC_ALL=C awk -v r="$rate" 'BEGIN{ printf "%.1f\n", r*100 }'
    exit 0
  fi
fi

exit 1
