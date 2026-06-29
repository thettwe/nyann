#!/usr/bin/env bash
# coverage-tools/go.sh — emit total line-coverage % for a Go project.
#
# Applies when <target>/go.mod exists. PREFERS an existing coverage
# profile (coverage.out / cover.out / coverage.txt, from `go test
# -coverprofile=...`) and reads the total via `go tool cover -func`, whose
# final `total:` row carries the aggregate percent. Soft-skips (exit
# non-zero, no output) when no profile is present — it deliberately does
# NOT run the whole suite, which would be slow and could block.
#
# Contract: print a bare percent and exit 0 when obtainable; else print
# nothing and exit non-zero.
target="${1:-$PWD}"

[[ -f "$target/go.mod" ]] || exit 1
# `go tool cover` needs the go toolchain.
command -v go >/dev/null 2>&1 || exit 1

profile=""
for cand in coverage.out cover.out coverage.txt; do
  if [[ -f "$target/$cand" ]]; then profile="$target/$cand"; break; fi
done
[[ -n "$profile" ]] || exit 1

# `go tool cover -func` ends with: `total:  (statements)  87.4%`.
pct=$( go tool cover -func="$profile" 2>/dev/null \
         | awk '/^total:/ { v=$NF; gsub("%","",v); print v; exit }' )
[[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 1
printf '%s\n' "$pct"
