#!/usr/bin/env bash
# license-tools/js.sh — emit dependency license rows for a JS/TS project.
#
# Applies when <target>/package.json exists AND the `license-checker` CLI
# is installed. Deliberately NEVER installs anything and never touches the
# network — it reads what license-checker reads (the installed node_modules
# tree), so a repo without an install soft-skips.
#
# Contract (shared by every license-tool): print a JSON array of
# {package, version, license} rows and exit 0 when an inventory is
# obtainable; otherwise print nothing and exit non-zero, meaning "not
# applicable / unavailable → soft-skip". license-checker keys packages as
# name@version (scoped names contain a leading @, so split on the LAST @)
# and emits `licenses` as a string OR an array — arrays join with " OR "
# (that is what a multi-licensed package means).
target="${1:-$PWD}"

[[ -f "$target/package.json" ]] || exit 1
command -v license-checker >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1

raw=$(license-checker --json --start "$target" 2>/dev/null) || exit 1
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || exit 1

jq '[to_entries[] | {
  package: (.key | split("@") | .[0:-1] | join("@")),
  version: (.key | split("@") | last),
  license: (if (.value.licenses | type) == "array"
            then (.value.licenses | join(" OR "))
            else (.value.licenses // "UNKNOWN") end)
}]' <<<"$raw"
