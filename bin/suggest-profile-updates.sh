#!/usr/bin/env bash
# suggest-profile-updates.sh — detect profile/repo mismatches and suggest updates.
#
# Usage:
#   suggest-profile-updates.sh --profile <path> --target <repo> [--stack <path>]
#
# Analyzes four signal sources and outputs JSON array of suggestions:
#   1. devDependencies vs profile hooks (installed-but-not-hooked)
#   2. Config files vs profile hooks (config-exists-but-not-hooked)
#   3. File structure (monorepo signals)
#   4. Git history (commit format drift)
#
# Output: JSON array of suggestion objects.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
stack_path=""

# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --profile)      profile_path="${2:-}"; shift 2 ;;
    --profile=*)    profile_path="${1#--profile=}"; shift ;;
    --stack)        stack_path="${2:-}"; shift 2 ;;
    --stack=*)      stack_path="${1#--stack=}"; shift ;;
    -h|--help)      sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
target="$(cd "$target" && pwd)"

profile_json=$(cat "$profile_path")
suggestions='[]'

add_suggestion() {
  local category="$1" signal="$2" suggestion="$3" confidence="$4" field="$5" add_val="$6"
  local action='{}'
  if [[ -n "$field" && -n "$add_val" ]]; then
    action=$(jq -n --arg f "$field" --arg a "$add_val" '{ field: $f, add: $a }')
  fi
  suggestions=$(jq --arg cat "$category" --arg sig "$signal" --arg sug "$suggestion" \
    --argjson conf "$confidence" --argjson act "$action" \
    '. + [{ category: $cat, signal: $sig, suggestion: $sug, confidence: $conf, action: $act }]' \
    <<<"$suggestions")
}

# --- Dependency-to-hook mapping table ----------------------------------------
# Format: dep_name:config_pattern:hook_id
declare -a TOOL_MAP=(
  "eslint:.eslintrc*|eslint.config.*:eslint"
  "prettier:.prettierrc*|prettier.config.*:prettier"
  "stylelint:.stylelintrc*:stylelint"
  "biome:biome.json:biome"
  "oxlint:oxlint.json:oxlint"
  "vitest:vitest.config.*:vitest"
  "jest:jest.config.*:jest"
  "ruff:ruff.toml:ruff"
  "black:pyproject.toml:black"
  "isort:.isort.cfg:isort"
  "mypy:mypy.ini:mypy"
  "pytest:pytest.ini|pyproject.toml:pytest"
  "flake8:.flake8:flake8"
  "golangci-lint:.golangci.yml|.golangci.yaml:golangci-lint"
  "clippy:Cargo.toml:clippy"
  "rustfmt:rustfmt.toml:fmt"
)

# Gather profile hooks into a flat list
all_hooks=$(jq -r '
  [(.hooks.pre_commit // [])[], (.hooks.commit_msg // [])[], (.hooks.pre_push // [])[]]
  | join(" ")
' <<<"$profile_json")

# --- Signal 1: devDependencies vs profile hooks ------------------------------

if [[ -f "$target/package.json" ]]; then
  dev_deps=$(jq -r '.devDependencies // {} | keys[]' "$target/package.json" 2>/dev/null || true)
  for entry in "${TOOL_MAP[@]}"; do
    dep_name="${entry%%:*}"
    hook_id="${entry##*:}"
    if echo "$dev_deps" | grep -Fxq "$dep_name"; then
      if ! echo "$all_hooks" | grep -Fq "$hook_id"; then
        add_suggestion "hook-gap" \
          "${dep_name} in devDependencies" \
          "Add ${hook_id} to pre_commit hooks" \
          0.9 "hooks.pre_commit" "$hook_id"
      fi
    fi
  done
fi

# --- Signal 2: Config files vs profile hooks ---------------------------------

for entry in "${TOOL_MAP[@]}"; do
  IFS=':' read -r dep_name config_pattern hook_id <<<"$entry"
  # Split config_pattern on | and check each
  IFS='|' read -ra patterns <<<"$config_pattern"
  for pat in "${patterns[@]}"; do
    # Use find with maxdepth 1 for root-level config files
    if find "$target" -maxdepth 1 -name "$pat" -print -quit 2>/dev/null | grep -q .; then
      if ! echo "$all_hooks" | grep -Fq "$hook_id"; then
        add_suggestion "config-present" \
          "config file matching ${pat} found" \
          "Add ${hook_id} to hooks (config file present but tool not hooked)" \
          0.8 "hooks.pre_commit" "$hook_id"
      fi
      break
    fi
  done
done

# --- Signal 3: Monorepo detection -------------------------------------------

if [[ -f "$target/package.json" ]]; then
  has_workspaces=$(jq -r 'if .workspaces then "true" else "false" end' "$target/package.json" 2>/dev/null)
  profile_workspaces=$(jq -r '.workspaces // {} | keys | length' <<<"$profile_json")
  if [[ "$has_workspaces" == "true" && "$profile_workspaces" -eq 0 ]]; then
    add_suggestion "structure" \
      "package.json has workspaces field" \
      "Add workspace entries to profile for monorepo support" \
      0.85 "" ""
  fi
fi

if [[ -f "$target/pnpm-workspace.yaml" ]]; then
  profile_workspaces=$(jq -r '.workspaces // {} | keys | length' <<<"$profile_json")
  if [[ "$profile_workspaces" -eq 0 ]]; then
    add_suggestion "structure" \
      "pnpm-workspace.yaml found" \
      "Add workspace entries to profile for monorepo support" \
      0.85 "" ""
  fi
fi

# --- Signal 4: Git history pattern analysis ----------------------------------

if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  recent_commits=$(git -C "$target" log --oneline -50 2>/dev/null || true)
  commit_count=0
  if [[ -n "$recent_commits" ]]; then
    commit_count=$(wc -l <<<"$recent_commits" | tr -d ' ')
  fi

  if [[ "$commit_count" -gt 0 ]]; then
    cc_regex='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_-]+\))?!?:'
    cc_count=$(git -C "$target" log --oneline -50 --format='%s' 2>/dev/null \
      | grep -cE "$cc_regex" || true)

    profile_format=$(jq -r '.conventions.commit_format' <<<"$profile_json")
    cc_ratio=0
    if [[ "$commit_count" -gt 0 ]]; then
      cc_ratio=$((cc_count * 100 / commit_count))
    fi

    # Confidence based on sample size
    confidence="0.5"
    if [[ "$commit_count" -ge 30 ]]; then
      confidence="0.9"
    elif [[ "$commit_count" -ge 10 ]]; then
      confidence="0.7"
    fi

    if [[ "$profile_format" == "conventional-commits" && "$cc_ratio" -lt 40 ]]; then
      add_suggestion "history-drift" \
        "${cc_ratio}% of recent commits follow conventional commits" \
        "Consider switching commit_format to 'custom' (most commits are freeform)" \
        "$confidence" "conventions.commit_format" "custom"
    elif [[ "$profile_format" != "conventional-commits" && "$cc_ratio" -gt 80 ]]; then
      add_suggestion "history-drift" \
        "${cc_ratio}% of recent commits match conventional commits" \
        "Consider switching commit_format to 'conventional-commits'" \
        "$confidence" "conventions.commit_format" "conventional-commits"
    fi

    # Detect scope usage
    if [[ "$cc_count" -gt 0 ]]; then
      scopes=$(git -C "$target" log --oneline -50 --format='%s' 2>/dev/null \
        | grep -oE '^\w+\(([^)]+)\)' | sed 's/.*(\(.*\))/\1/' | sort -u || true)
      profile_scopes=$(jq -r '.conventions.commit_scopes // [] | .[]' <<<"$profile_json")

      while IFS= read -r scope; do
        [[ -z "$scope" ]] && continue
        if ! echo "$profile_scopes" | grep -Fxq "$scope"; then
          add_suggestion "scope-gap" \
            "scope '${scope}' used in commits but not in profile" \
            "Add '${scope}' to conventions.commit_scopes" \
            "$confidence" "conventions.commit_scopes" "$scope"
        fi
      done <<<"$scopes"
    fi
  fi
fi

# Deduplicate suggestions (same hook_id can appear from both dep and config signals)
suggestions=$(jq '[group_by(.action.add // .signal) | .[] | .[0]]' <<<"$suggestions")

printf '%s\n' "$suggestions"
