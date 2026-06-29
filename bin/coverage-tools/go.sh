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

# Pin the toolchain selector so the repo's go.mod cannot redirect it.
# Under the default GOTOOLCHAIN=auto a crafted `toolchain`/`go` directive
# makes even `go tool cover` download and re-exec a ~100MB toolchain over
# the network — a repo-triggered stall that would block the pr/ship flow.
# GOTOOLCHAIN=local forces the installed toolchain (never downloads/switches);
# GOPROXY=off is belt-and-suspenders against any module fetch.
export GOTOOLCHAIN=local GOPROXY=off

# `go tool cover -func` ends with: `total:  (statements)  87.4%`.
# Wrap in a hard timeout when available so any unexpected stall still cannot
# block — the guard must never hang the flow (GNU/BSD `timeout`/`gtimeout`).
if command -v timeout >/dev/null 2>&1; then
  run_cover() { timeout 20 go tool cover -func="$profile"; }
elif command -v gtimeout >/dev/null 2>&1; then
  run_cover() { gtimeout 20 go tool cover -func="$profile"; }
else
  run_cover() { go tool cover -func="$profile"; }
fi

pct=$( run_cover 2>/dev/null \
         | LC_ALL=C awk '/^total:/ { v=$NF; gsub("%","",v); print v; exit }' )
[[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 1
printf '%s\n' "$pct"
