#!/usr/bin/env bash
# license-tools/python.sh — emit dependency license rows for a Python project.
#
# Applies when a Python manifest exists AND `pip-licenses` is installed
# (it reads the ACTIVE environment's installed packages — a repo whose venv
# isn't set up soft-skips). Same contract as every license-tool: JSON array
# of {package, version, license} on stdout + exit 0, or nothing + non-zero.
target="${1:-$PWD}"

[[ -f "$target/pyproject.toml" || -f "$target/requirements.txt" || -f "$target/setup.cfg" ]] || exit 1
command -v pip-licenses >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1

raw=$(pip-licenses --format=json 2>/dev/null) || exit 1
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || exit 1

jq 'map({package: .Name, version: (.Version // null), license: (.License // "UNKNOWN")})' <<<"$raw"
