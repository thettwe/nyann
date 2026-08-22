#!/usr/bin/env bash
# license-tools/go.sh — emit dependency license rows for a Go project.
#
# Applies when <target>/go.mod exists AND `go-licenses` is installed.
# `go-licenses report ./...` emits CSV rows `module,license-url,license`;
# it needs the module cache populated (a fresh clone without `go mod
# download` may partially fail — stderr is discarded and whatever rows it
# CAN produce are used; zero rows soft-skips). Version is not part of the
# report format, so rows carry version:null. Same contract as every
# license-tool: JSON array + exit 0, or nothing + non-zero.
target="${1:-$PWD}"

[[ -f "$target/go.mod" ]] || exit 1
command -v go-licenses >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1

raw=$(cd "$target" && go-licenses report ./... 2>/dev/null) || true
[[ -n "$raw" ]] || exit 1

printf '%s\n' "$raw" \
  | awk -F',' 'NF >= 3 {print $1 "\t" $3}' \
  | jq -R 'split("\t") | select(length == 2) | {package: .[0], version: null, license: (.[1] | if . == "" then "UNKNOWN" else . end)}' \
  | jq -s '.'
