#!/usr/bin/env bash
# resolve-workspace-configs.sh — merge detected workspaces with profile overrides.
#
# Usage: resolve-workspace-configs.sh --stack <stack.json> --profile <profile.json>
#                                     [--plugin-root <dir>] [--user-root <dir>]
#
# Reads the workspaces[] array from the StackDescriptor and the optional
# workspaces{} map from the Profile. For each detected workspace, resolves
# hooks, extras, and documentation by applying (in priority order):
#   1. Named workspace profile (e.g. "apps/web": {"profile": "react-vite"})
#   2. Exact-path override from profile  (e.g. "apps/web": {hooks:...})
#   3. Wildcard override from profile    ("*": {...})
#   4. Language-based defaults           (typescript → eslint+prettier, etc.)
#
# When a workspace declares "profile": "<name>", the named profile is loaded
# and its hooks/extras/ci/documentation fields override the language defaults.
# Explicit hooks/extras in the workspace override still win over the named profile.
#
# Emits a JSON array to stdout. Each entry:
#   { path, primary_language, framework, package_manager, hooks, extras,
#     profile?, ci?, documentation? }
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
plugin_root="$(cd "${_script_dir}/.." && pwd)"
user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)        stack_file="${2:-}"; shift 2 ;;
    --stack=*)      stack_file="${1#--stack=}"; shift ;;
    --profile)      profile_file="${2:-}"; shift 2 ;;
    --profile=*)    profile_file="${1#--profile=}"; shift ;;
    --plugin-root)  plugin_root="${2:-}"; shift 2 ;;
    --plugin-root=*) plugin_root="${1#--plugin-root=}"; shift ;;
    --user-root)    user_root="${2:-}"; shift 2 ;;
    --user-root=*)  user_root="${1#--user-root=}"; shift ;;
    -h|--help)      sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# --- load named profile -------------------------------------------------------
# Resolves a workspace-supplied profile name to its JSON content. Routes
# through bin/load-profile.sh so the load goes through the same name
# validation (rejects traversal / unsafe characters), schema validation,
# and source resolution (user > team > starter) as every other profile
# read path. Returns the profile JSON on stdout, or empty string if the
# name is invalid or the profile is not found.

load_named_profile() {
  local name="$1"
  # First-line defense: reject names that don't match the profile-name
  # grammar. load-profile.sh also re-validates, but stopping here keeps
  # the warn message specific to the workspace config and avoids spawning
  # a subprocess for an obviously bad input.
  if ! nyann::valid_profile_name "$name" && ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*$ ]]; then
    nyann::warn "workspace profile name rejected (must be [a-z0-9][a-z0-9-]* or team/[a-z0-9][a-z0-9-]*): $name"
    return 0
  fi
  # Suppress load-profile.sh's stderr so a missing profile produces an
  # empty stdout (the existing caller treats empty as "not found" and
  # falls back to defaults). Real load failures still appear in the
  # nyann::warn the caller emits.
  "${_script_dir}/load-profile.sh" "$name" \
    --user-root "$user_root" \
    --plugin-root "$plugin_root" 2>/dev/null || true
}

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

  # Check for named workspace profile
  named_profile_name=""
  named_profile_json=""
  if [[ "$exact_override" != "null" ]]; then
    named_profile_name=$(jq -r '.profile // ""' <<<"$exact_override")
  fi
  if [[ -z "$named_profile_name" ]] && [[ "$wildcard_override" != "null" ]]; then
    named_profile_name=$(jq -r '.profile // ""' <<<"$wildcard_override")
  fi
  if [[ -n "$named_profile_name" ]]; then
    named_profile_json=$(load_named_profile "$named_profile_name")
    if [[ -z "$named_profile_json" ]]; then
      nyann::warn "workspace $ws_path: profile '$named_profile_name' not found; falling back to defaults"
      named_profile_name=""
    fi
  fi

  # Resolution priority:
  #   1. Named profile hooks/extras (full profile loaded)
  #   2. Exact-path override hooks/extras (inline overrides win over named profile)
  #   3. Wildcard override
  #   4. Language defaults
  resolved_owner=""
  resolved_ci="null"
  resolved_documentation="null"

  if [[ -n "$named_profile_name" && -n "$named_profile_json" ]]; then
    # Layer 1: defaults -> named profile
    profile_hooks=$(jq -c '.hooks // {}' <<<"$named_profile_json")
    resolved_hooks=$(jq -c --argjson d "$defaults" --argjson ph "$profile_hooks" \
      -n '$d * $ph' <<<"")
    base_extras=$(jq -c '.extras // {}' <<<"$named_profile_json")
    resolved_extras=$(jq -c --argjson d "$default_extras" --argjson pe "$base_extras" \
      '$d * $pe' -n <<<"")
    resolved_ci=$(jq -c '.ci // null' <<<"$named_profile_json")
    resolved_documentation=$(jq -c '.documentation // null' <<<"$named_profile_json")

    # Layer 2: wildcard override (shared policy across all workspaces).
    # All four override-able sections (hooks/extras/ci/documentation) deep-merge
    # onto the named-profile base so wildcard policy can adjust any field
    # without forcing the workspace to re-declare the whole object.
    if [[ "$wildcard_override" != "null" ]]; then
      wc_has_hooks=$(jq 'has("hooks")' <<<"$wildcard_override")
      wc_has_extras=$(jq 'has("extras")' <<<"$wildcard_override")
      wc_has_ci=$(jq 'has("ci")' <<<"$wildcard_override")
      wc_has_doc=$(jq 'has("documentation")' <<<"$wildcard_override")
      if [[ "$wc_has_hooks" == "true" ]]; then
        resolved_hooks=$(jq -c --argjson base "$resolved_hooks" \
          '.hooks as $h | $base * ($h // {})' <<<"$wildcard_override")
      fi
      if [[ "$wc_has_extras" == "true" ]]; then
        resolved_extras=$(jq -c --argjson base "$resolved_extras" \
          '.extras as $e | $base * ($e // {})' <<<"$wildcard_override")
      fi
      if [[ "$wc_has_ci" == "true" ]]; then
        wc_ci=$(jq -c '.ci' <<<"$wildcard_override")
        if [[ "$resolved_ci" == "null" ]]; then
          resolved_ci="$wc_ci"
        else
          resolved_ci=$(jq -nc --argjson base "$resolved_ci" --argjson ov "$wc_ci" '$base * $ov')
        fi
      fi
      if [[ "$wc_has_doc" == "true" ]]; then
        wc_doc=$(jq -c '.documentation' <<<"$wildcard_override")
        if [[ "$resolved_documentation" == "null" ]]; then
          resolved_documentation="$wc_doc"
        else
          resolved_documentation=$(jq -nc --argjson base "$resolved_documentation" --argjson ov "$wc_doc" '$base * $ov')
        fi
      fi
      resolved_owner=$(jq -r '.owner // ""' <<<"$wildcard_override")
    fi

    # Layer 3: exact-path override (workspace-specific wins over all)
    if [[ "$exact_override" != "null" ]]; then
      has_hooks=$(jq 'has("hooks")' <<<"$exact_override")
      has_extras=$(jq 'has("extras")' <<<"$exact_override")
      has_ci=$(jq 'has("ci")' <<<"$exact_override")
      has_doc=$(jq 'has("documentation")' <<<"$exact_override")
      if [[ "$has_hooks" == "true" ]]; then
        resolved_hooks=$(jq -c --argjson base "$resolved_hooks" \
          '.hooks as $h | $base * ($h // {})' <<<"$exact_override")
      fi
      if [[ "$has_extras" == "true" ]]; then
        resolved_extras=$(jq -c --argjson base "$resolved_extras" \
          '.extras as $e | $base * ($e // {})' <<<"$exact_override")
      fi
      if [[ "$has_ci" == "true" ]]; then
        ex_ci=$(jq -c '.ci' <<<"$exact_override")
        if [[ "$resolved_ci" == "null" ]]; then
          resolved_ci="$ex_ci"
        else
          resolved_ci=$(jq -nc --argjson base "$resolved_ci" --argjson ov "$ex_ci" '$base * $ov')
        fi
      fi
      if [[ "$has_doc" == "true" ]]; then
        ex_doc=$(jq -c '.documentation' <<<"$exact_override")
        if [[ "$resolved_documentation" == "null" ]]; then
          resolved_documentation="$ex_doc"
        else
          resolved_documentation=$(jq -nc --argjson base "$resolved_documentation" --argjson ov "$ex_doc" '$base * $ov')
        fi
      fi
      ex_owner=$(jq -r '.owner // ""' <<<"$exact_override")
      [[ -n "$ex_owner" ]] && resolved_owner="$ex_owner"
    fi
  elif [[ "$exact_override" != "null" ]]; then
    # Exact-path match: merge with defaults (override wins).
    resolved_hooks=$(jq -c --argjson d "$defaults" \
      '.hooks as $h | $d * ($h // {})' <<<"$exact_override")
    resolved_extras=$(jq -c --argjson d "$default_extras" \
      '.extras as $e | $d * ($e // {})' <<<"$exact_override")
    resolved_owner=$(jq -r '.owner // ""' <<<"$exact_override")
    # Inline documentation/ci on the exact override land directly (no
    # named-profile to inherit from). Wildcard fills any gaps.
    resolved_ci=$(jq -c '.ci // null' <<<"$exact_override")
    resolved_documentation=$(jq -c '.documentation // null' <<<"$exact_override")
    if [[ "$wildcard_override" != "null" ]]; then
      if [[ -z "$resolved_owner" ]]; then
        resolved_owner=$(jq -r '.owner // ""' <<<"$wildcard_override")
      fi
      if [[ "$resolved_ci" == "null" ]]; then
        resolved_ci=$(jq -c '.ci // null' <<<"$wildcard_override")
      fi
      if [[ "$resolved_documentation" == "null" ]]; then
        resolved_documentation=$(jq -c '.documentation // null' <<<"$wildcard_override")
      fi
    fi
  elif [[ "$wildcard_override" != "null" ]]; then
    # Wildcard match: merge with defaults.
    resolved_hooks=$(jq -c --argjson d "$defaults" \
      '.hooks as $h | $d * ($h // {})' <<<"$wildcard_override")
    resolved_extras=$(jq -c --argjson d "$default_extras" \
      '.extras as $e | $d * ($e // {})' <<<"$wildcard_override")
    resolved_owner=$(jq -r '.owner // ""' <<<"$wildcard_override")
    resolved_ci=$(jq -c '.ci // null' <<<"$wildcard_override")
    resolved_documentation=$(jq -c '.documentation // null' <<<"$wildcard_override")
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
    --arg profile_name "$named_profile_name" \
    --argjson ci "$resolved_ci" \
    --argjson documentation "$resolved_documentation" \
    '{
      path: $path,
      primary_language: $lang,
      framework: $framework,
      package_manager: $package_manager,
      hooks: $hooks,
      extras: $extras
    }
    + (if $owner == "" then {} else {owner: $owner} end)
    + (if $profile_name == "" then {} else {profile: $profile_name} end)
    + (if $ci == null then {} else {ci: $ci} end)
    + (if $documentation == null then {} else {documentation: $documentation} end)')

  result=$(jq --argjson e "$entry" '. + [$e]' <<<"$result")
done

jq '.' <<<"$result"
