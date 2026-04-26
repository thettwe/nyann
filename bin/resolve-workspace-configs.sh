#!/usr/bin/env bash
# resolve-workspace-configs.sh — merge detected workspaces with profile overrides.
#
# Usage: resolve-workspace-configs.sh --stack <stack.json> --profile <profile.json>
#
# Reads the workspaces[] array from the StackDescriptor and the optional
# workspaces{} map from the Profile. For each detected workspace, resolves
# hooks and extras by applying (in priority order):
#   1. Exact-path override from profile  (e.g. "apps/web": {...})
#   2. Wildcard override from profile    ("*": {...})
#   3. Language-based defaults           (typescript → eslint+prettier, etc.)
#
# Emits a JSON array to stdout. Each entry:
#   { path, primary_language, framework, package_manager, hooks, extras }
#
# Exit codes:
#   0 — resolved (may be empty array if no workspaces detected)
#   1 — bad input or missing required files

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

stack_file=""
profile_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)        stack_file="${2:-}"; shift 2 ;;
    --stack=*)      stack_file="${1#--stack=}"; shift ;;
    --profile)      profile_file="${2:-}"; shift 2 ;;
    --profile=*)    profile_file="${1#--profile=}"; shift ;;
    -h|--help)      sed -n '3,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)              nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$stack_file" ]]   || nyann::die "usage: --stack <stack.json> required"
[[ -n "$profile_file" ]] || nyann::die "usage: --profile <profile.json> required"
[[ -f "$stack_file" ]]   || nyann::die "stack file not found: $stack_file"
[[ -f "$profile_file" ]] || nyann::die "profile file not found: $profile_file"

stack=$(cat "$stack_file")
profile=$(cat "$profile_file")

is_monorepo=$(jq -r '.is_monorepo // false' <<<"$stack")
if [[ "$is_monorepo" != "true" ]]; then
  echo '[]'
  exit 0
fi

workspaces=$(jq -c '.workspaces // []' <<<"$stack")
ws_count=$(jq 'length' <<<"$workspaces")

if (( ws_count == 0 )); then
  echo '[]'
  exit 0
fi

profile_ws=$(jq -c '.workspaces // {}' <<<"$profile")
wildcard_override=$(jq -c '.["*"] // null' <<<"$profile_ws")

# --- default hooks by language ------------------------------------------------

default_hooks_for_lang() {
  local lang="$1"
  local hooks
  # Hook IDs MUST match what the language's pre-commit template
  # actually exposes — install-hooks.sh installs from
  # templates/pre-commit-configs/<lang>.yaml. For Rust the template
  # uses doublify/pre-commit-rust which exposes `fmt` + `clippy`,
  # not `cargo-check`/`rustfmt`. The starter rust profiles already
  # use `["fmt","clippy"]`; aligning here keeps monorepo workspaces
  # consistent with single-stack repos.
  case "$lang" in
    typescript|javascript) hooks='["eslint","prettier"]' ;;
    python)                hooks='["ruff","ruff-format"]' ;;
    go)                    hooks='["go-vet","gofmt"]' ;;
    rust)                  hooks='["fmt","clippy"]' ;;
    *)                     hooks='[]' ;;
  esac
  jq -nc --argjson h "$hooks" '{pre_commit:$h, commit_msg:[], pre_push:[]}'
}

default_extras=$(jq -nc '{gitignore:false, editorconfig:false}')

# --- resolve each workspace ---------------------------------------------------

result='[]'

for (( i=0; i<ws_count; i++ )); do
  ws=$(jq -c ".[$i]" <<<"$workspaces")
  ws_path=$(jq -r '.path' <<<"$ws")
  ws_lang=$(jq -r '.primary_language // "unknown"' <<<"$ws")
  ws_framework=$(jq -c '.framework' <<<"$ws")
  ws_pm=$(jq -c '.package_manager' <<<"$ws")

  exact_override=$(jq -c --arg p "$ws_path" '.[$p] // null' <<<"$profile_ws")

  defaults=$(default_hooks_for_lang "$ws_lang")

  # Resolve owner with the same precedence as hooks/extras: exact > wildcard.
  # gen-codeowners.sh reads .owner per-entry; if the resolver doesn't
  # forward it, every workspace falls back to --default-owner ("*") and
  # profile.workspaces.<key>.owner becomes a no-op despite being declared
  # in the profile schema.
  resolved_owner=""
  if [[ "$exact_override" != "null" ]]; then
    # Exact-path match: merge with defaults (override wins).
    resolved_hooks=$(jq -c --argjson d "$defaults" \
      '.hooks as $h | $d * ($h // {})' <<<"$exact_override")
    resolved_extras=$(jq -c --argjson d "$default_extras" \
      '.extras as $e | $d * ($e // {})' <<<"$exact_override")
    resolved_owner=$(jq -r '.owner // ""' <<<"$exact_override")
    if [[ -z "$resolved_owner" ]] && [[ "$wildcard_override" != "null" ]]; then
      resolved_owner=$(jq -r '.owner // ""' <<<"$wildcard_override")
    fi
  elif [[ "$wildcard_override" != "null" ]]; then
    # Wildcard match: merge with defaults.
    resolved_hooks=$(jq -c --argjson d "$defaults" \
      '.hooks as $h | $d * ($h // {})' <<<"$wildcard_override")
    resolved_extras=$(jq -c --argjson d "$default_extras" \
      '.extras as $e | $d * ($e // {})' <<<"$wildcard_override")
    resolved_owner=$(jq -r '.owner // ""' <<<"$wildcard_override")
  else
    # Pure language-based defaults.
    resolved_hooks="$defaults"
    resolved_extras="$default_extras"
  fi

  entry=$(jq -n -c \
    --arg path "$ws_path" \
    --arg lang "$ws_lang" \
    --argjson framework "$ws_framework" \
    --argjson package_manager "$ws_pm" \
    --argjson hooks "$resolved_hooks" \
    --argjson extras "$resolved_extras" \
    --arg owner "$resolved_owner" \
    '{
      path: $path,
      primary_language: $lang,
      framework: $framework,
      package_manager: $package_manager,
      hooks: $hooks,
      extras: $extras
    }
    + (if $owner == "" then {} else {owner: $owner} end)')

  result=$(jq --argjson e "$entry" '. + [$e]' <<<"$result")
done

jq '.' <<<"$result"
