#!/usr/bin/env bash
# coverage-tools/js.sh — emit total line-coverage % for a JS/TS project.
#
# Applies when <target>/package.json exists. PREFERS an existing coverage
# artifact (coverage/coverage-summary.json — written by jest --coverage /
# c8 / nyc) and reads `.total.lines.pct`. Coverage runs are slow, so this
# deliberately NEVER runs the test suite itself: it soft-skips (exit
# non-zero, no output) when no artifact is present. Pair it with a profile
# / CI that already produces the summary (e.g. `jest --coverage
# --coverageReporters=json-summary`).
#
# Contract (shared by every coverage-tool): print a bare percent (e.g.
# `87.4`) and exit 0 when a figure is obtainable; otherwise print nothing
# and exit non-zero, meaning "not applicable / unavailable → soft-skip".
target="${1:-$PWD}"

# Not a JS/TS project → not applicable.
[[ -f "$target/package.json" ]] || exit 1
# jq absent → degrade to soft-skip rather than mis-parse.
command -v jq >/dev/null 2>&1 || exit 1

summary="$target/coverage/coverage-summary.json"
[[ -f "$summary" ]] || exit 1

pct=$(jq -r '.total.lines.pct // empty' "$summary" 2>/dev/null || true)
[[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 1
printf '%s\n' "$pct"
