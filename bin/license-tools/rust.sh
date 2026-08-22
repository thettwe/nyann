#!/usr/bin/env bash
# license-tools/rust.sh — emit dependency license rows for a Rust project.
#
# Applies when <target>/Cargo.toml exists AND the `cargo-license` cargo
# subcommand is installed (`cargo license --json` reads Cargo.lock /
# registry metadata). Same contract as every license-tool: JSON array of
# {package, version, license} on stdout + exit 0, or nothing + non-zero.
target="${1:-$PWD}"

[[ -f "$target/Cargo.toml" ]] || exit 1
command -v cargo-license >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1

raw=$(cd "$target" && cargo license --json 2>/dev/null) || exit 1
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || exit 1

jq 'map({package: .name, version: (.version // null), license: (.license // "UNKNOWN")})' <<<"$raw"
