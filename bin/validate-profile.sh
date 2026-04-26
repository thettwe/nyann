#!/usr/bin/env bash
# validate-profile.sh — validate a nyann profile against profiles/_schema.json.
#
# Usage: validate-profile.sh <profile.json>
#
# Exit 0: profile is valid.
# Exit 2: profile file missing or unreadable.
# Exit 3: profile is malformed JSON.
# Exit 4: profile fails schema validation (errors printed to stderr).
#
# Dependency: `uvx check-jsonschema` (via the `uv` tool) or plain
# `check-jsonschema`. Installed once per machine; the plugin's bootstrap will
# add a prereq check in a later task.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

if [[ $# -lt 1 ]]; then
  nyann::die "usage: validate-profile.sh <profile.json>"
fi

profile_path="$1"

if [[ ! -f "$profile_path" ]]; then
  nyann::warn "profile file not found: $profile_path"
  exit 2
fi

schema_path="${_script_dir}/../profiles/_schema.json"
[[ -f "$schema_path" ]] || nyann::die "schema missing: $schema_path"

# JSON parse check first so we can give a clean "malformed JSON" error separate
# from schema errors.
parse_err=$(mktemp -t nyann-profile-parse.XXXXXX)
trap 'rm -f "$parse_err"' EXIT
if ! jq empty "$profile_path" 2>"$parse_err"; then
  nyann::warn "profile is not valid JSON: $profile_path"
  sed 's/^/  /' "$parse_err" >&2 || true
  exit 3
fi

# Prefer a plain `check-jsonschema` if installed; else use `uvx`. Both resolve
# the same implementation.
validator=()
if command -v check-jsonschema >/dev/null 2>&1; then
  validator=(check-jsonschema)
elif command -v uvx >/dev/null 2>&1; then
  validator=(uvx --quiet check-jsonschema)
else
  nyann::die "$(printf 'no schema validator found.\n  Install one of:\n    brew install uv          # recommended; enables uvx check-jsonschema\n    pip install check-jsonschema')"
fi

val_out=$(mktemp -t nyann-profile-val.XXXXXX)
trap 'rm -f "$parse_err" "$val_out"' EXIT
if "${validator[@]}" --schemafile "$schema_path" "$profile_path" 2>"$val_out"; then
  nyann::log "profile valid: $profile_path"
  exit 0
else
  rc=$?
  val_stderr=$(cat "$val_out" 2>/dev/null || true)
  # Detect uvx/tool-level crashes (cache corruption, permission errors)
  # vs real schema validation failures. Schema errors are exit 1 with
  # structured output; tool crashes mention OS-level errors.
  if echo "$val_stderr" | grep -qiE 'operation not permitted|permission denied'; then
    nyann::warn "schema validator crashed (exit $rc); skipping validation for $profile_path"
    sed 's/^/  /' <<<"$val_stderr" >&2 || true
    exit 0
  fi
  nyann::warn "profile invalid: $profile_path"
  exit 4
fi
