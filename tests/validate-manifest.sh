#!/usr/bin/env bash
# validate-manifest.sh — structural validation of the plugin + marketplace
# manifests, independent of the `claude` CLI (which isn't installed in CI).
#
# Catches the failure mode where a malformed/inconsistent manifest passes
# lint + bats but only breaks at plugin-install time: invalid JSON, missing
# required fields, version/name drift between the two files, or a marketplace
# `source` that doesn't resolve on disk.
#
# Exit codes: 0 — valid; 1 — a problem was found.

set -o errexit
set -o nounset
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin="$repo_root/.claude-plugin/plugin.json"
marketplace="$repo_root/.claude-plugin/marketplace.json"

fail() { echo "validate-manifest: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

[[ -f "$plugin" ]]      || fail "missing $plugin"
[[ -f "$marketplace" ]] || fail "missing $marketplace"

jq -e . "$plugin"      >/dev/null 2>&1 || fail "plugin.json is not valid JSON"
jq -e . "$marketplace" >/dev/null 2>&1 || fail "marketplace.json is not valid JSON"

# --- plugin.json required fields ---------------------------------------------
for field in name version description author license repository; do
  jq -e --arg f "$field" 'has($f) and (.[$f] != null and .[$f] != "")' "$plugin" >/dev/null \
    || fail "plugin.json missing required field: $field"
done

# semver-ish version (allows -rc.N / -beta.N prereleases)
plugin_version=$(jq -r '.version' "$plugin")
[[ "$plugin_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
  || fail "plugin.json version is not semver: $plugin_version"

plugin_name=$(jq -r '.name' "$plugin")

# --- marketplace.json required structure -------------------------------------
for field in name owner plugins; do
  jq -e --arg f "$field" 'has($f) and (.[$f] != null)' "$marketplace" >/dev/null \
    || fail "marketplace.json missing required field: $field"
done

jq -e '.plugins | type == "array" and length >= 1' "$marketplace" >/dev/null \
  || fail "marketplace.json .plugins must be a non-empty array"

# Locate this plugin's marketplace entry by name.
entry=$(jq -c --arg n "$plugin_name" '.plugins[] | select(.name == $n)' "$marketplace")
[[ -n "$entry" ]] || fail "marketplace.json has no plugins[] entry named '$plugin_name'"

for field in name source description version; do
  jq -e --arg f "$field" 'has($f) and (.[$f] != null and .[$f] != "")' <<<"$entry" >/dev/null \
    || fail "marketplace.json plugins['$plugin_name'] missing field: $field"
done

# --- cross-file consistency --------------------------------------------------
entry_version=$(jq -r '.version' <<<"$entry")
[[ "$entry_version" == "$plugin_version" ]] \
  || fail "version drift: plugin.json=$plugin_version vs marketplace entry=$entry_version"

# --- source path resolves on disk --------------------------------------------
src=$(jq -r '.source' <<<"$entry")
src_path="$repo_root/$src"
[[ -d "$src_path" ]] || fail "marketplace source '$src' does not resolve to a directory"
[[ -f "$src_path/.claude-plugin/plugin.json" ]] \
  || fail "marketplace source '$src' does not contain .claude-plugin/plugin.json"

echo "validate-manifest: OK (plugin '$plugin_name' v$plugin_version)"
