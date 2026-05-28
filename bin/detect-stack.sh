#!/usr/bin/env bash
# detect-stack.sh — inspect a repo and emit a StackDescriptor JSON.
#
# Usage: detect-stack.sh [--path <dir>]
# Default path is the current working directory.
#
# Output: JSON StackDescriptor to stdout (see schemas/stack-descriptor.schema.json).
# Exit 0 on success; exit 1 on argument or filesystem error.
#
# Covers JS/TS, Python, Go, Rust stacks with confidence scoring and
# schema-validated output.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# --- arg parsing --------------------------------------------------------------

path=""
emit_workspaces=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      path="${2:-}"
      shift 2
      ;;
    --path=*)
      path="${1#--path=}"
      shift
      ;;
    --no-workspaces)
      # Used during recursive workspace iteration so we don't recurse forever.
      emit_workspaces=false
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
detect-stack.sh — emit a StackDescriptor JSON for a repo.

Usage:
  detect-stack.sh [--path <dir>] [--no-workspaces]

Flags:
  --path <dir>       Repo root to inspect. Defaults to the current directory.
  --no-workspaces    Skip the per-workspace sub-descriptor pass (used internally).
  -h, --help         Show this help.
USAGE
      exit 0
      ;;
    *)
      nyann::die "unknown argument: $1"
      ;;
  esac
done

path="${path:-$PWD}"
[[ -d "$path" ]] || nyann::die "path is not a directory: $path"
path="$(cd "$path" && pwd)"

# --- accumulator state --------------------------------------------------------

_reasons=""

add_reason() {
  if [[ -n "$_reasons" ]]; then
    _reasons="${_reasons}"$'\n'"$1"
  else
    _reasons="$1"
  fi
}

primary_language="unknown"
secondary_languages_json='[]'
framework="null"
package_manager="null"

signal_manifest=0
signal_claudemd=0
signal_docs=0
signal_lock=0
signal_ext=0

# --- source detector modules --------------------------------------------------
_detect_dir="${_script_dir}/detect-stack"

# shellcheck source=detect-stack/detect-jsts.sh
source "${_detect_dir}/detect-jsts.sh"
# shellcheck source=detect-stack/detect-python.sh
source "${_detect_dir}/detect-python.sh"
# shellcheck source=detect-stack/detect-go-rust.sh
source "${_detect_dir}/detect-go-rust.sh"
# shellcheck source=detect-stack/detect-mobile-systems.sh
source "${_detect_dir}/detect-mobile-systems.sh"
# shellcheck source=detect-stack/detect-v110-stacks.sh
source "${_detect_dir}/detect-v110-stacks.sh"
# shellcheck source=detect-stack/detect-hints.sh
source "${_detect_dir}/detect-hints.sh"
# shellcheck source=detect-stack/discover-workspaces.sh
source "${_detect_dir}/discover-workspaces.sh"

# --- history signal initializers --------------------------------------------
# These are read by the detectors above (detect_rust may set is_monorepo to
# true for Cargo workspaces) so initialize before dispatch. Git + CHANGELOG
# signals are filled after detection — they don't influence the stack pick.

has_git=false
git_is_empty_repo=false
has_changelog=false
has_semver_tags=false
contributor_count=0
existing_precommit_config="none"
existing_ci="none"
has_claude_md=false
is_monorepo=false
monorepo_tool="null"

# --- dispatch -----------------------------------------------------------------

detect_jsts || true
detect_python || true
detect_go || true
detect_rust || true
detect_swift || true
detect_kotlin || true
detect_java || true
detect_dotnet || true
detect_php || true
detect_dart || true
detect_ruby || true
# New v1.10.0 detectors. Ordered after the established stacks so an
# existing detection path can claim primary first; these only set
# primary_language when nothing else matched. detect_deno() runs
# AFTER detect_jsts() so a `deno.json + package.json` polyglot
# stays on the JS/TS path.
detect_deno     || true
detect_elixir   || true
detect_cpp_cmake || true
detect_shell || true
detect_claudemd_hints || true
detect_doc_hints || true
detect_by_extension_counts || true

# --- git / history signals (read after detection) ---------------------------

if [[ -d "$path/.git" ]]; then
  has_git=true
  if ! git -C "$path" rev-parse --verify HEAD >/dev/null 2>&1; then
    git_is_empty_repo=true
  else
    contributor_count=$(git -C "$path" shortlog -sn HEAD 2>/dev/null | wc -l | tr -d ' ')
    if git -C "$path" tag -l 'v[0-9]*' 2>/dev/null | grep -Eq '^v[0-9]+\.[0-9]+'; then
      has_semver_tags=true
    fi
  fi
fi

[[ -f "$path/CHANGELOG.md" ]] && has_changelog=true
[[ -f "$path/CLAUDE.md" ]] && has_claude_md=true
[[ -f "$path/.husky/pre-commit" ]] && existing_precommit_config="husky"
[[ -f "$path/.pre-commit-config.yaml" ]] && existing_precommit_config="pre-commit.com"
[[ -d "$path/.github/workflows" ]] && existing_ci="github-actions"

if [[ "$is_monorepo" != "true" ]]; then
  # Only claim JS/TS monorepo tooling if nothing else already set is_monorepo
  # (detect_rust claims cargo-workspace when Cargo.toml has [workspace]).
  if [[ -f "$path/pnpm-workspace.yaml" ]]; then
    is_monorepo=true
    monorepo_tool='"pnpm-workspaces"'
  elif [[ -f "$path/turbo.json" ]]; then
    is_monorepo=true
    monorepo_tool='"turbo"'
  elif [[ -f "$path/nx.json" ]]; then
    is_monorepo=true
    monorepo_tool='"nx"'
  elif [[ -f "$path/lerna.json" ]]; then
    is_monorepo=true
    monorepo_tool='"lerna"'
  fi
fi

# --- Workspace iteration -----------------------------------------------------
# When is_monorepo and --no-workspaces wasn't set, discover workspace dirs
# from the monorepo manifest and run detect-stack.sh --no-workspaces on each.
# Only a subset of fields is kept per workspace (path, primary_language,
# framework, package_manager). Cargo workspaces are deferred.

workspaces_json='[]'

if $emit_workspaces && [[ "$is_monorepo" == "true" ]]; then
  while IFS= read -r ws; do
    [[ -z "$ws" ]] && continue
    sub_path="$path/$ws"
    [[ -d "$sub_path" ]] || continue
    sub=$("${_script_dir}/detect-stack.sh" --path "$sub_path" --no-workspaces 2>/dev/null || true)
    [[ -z "$sub" ]] && continue
    entry=$(jq --arg p "$ws" '{
      path: $p,
      primary_language: .primary_language,
      framework: .framework,
      package_manager: .package_manager
    }' <<<"$sub")
    workspaces_json=$(jq --argjson e "$entry" '. + [$e]' <<<"$workspaces_json")

    # Fold workspace's language into root's secondary_languages so the flat
    # view still surfaces the polyglot nature. Skip the root's own primary.
    ws_lang=$(jq -r '.primary_language' <<<"$sub")
    if [[ -n "$ws_lang" && "$ws_lang" != "unknown" && "$ws_lang" != "$primary_language" ]]; then
      already=$(jq --arg l "$ws_lang" 'any(. == $l)' <<<"$secondary_languages_json")
      if [[ "$already" != "true" ]]; then
        secondary_languages_json=$(jq --arg l "$ws_lang" '. + [$l]' <<<"$secondary_languages_json")
      fi
    fi
  done < <(discover_workspaces)
fi

# --- Confidence computation ---------------------------------------------------
# Weighted confidence sum. Using awk for float math keeps us independent of
# bc/python.

confidence=$(awk -v m="$signal_manifest" -v c="$signal_claudemd" -v d="$signal_docs" -v l="$signal_lock" -v e="$signal_ext" \
  'BEGIN {
     s = m*0.5 + c*0.3 + d*0.2 + l*0.15 + e*0.05;
     if (s > 1.0) s = 1.0;
     if (s < 0.0) s = 0.0;
     printf "%.2f", s;
   }')

archetype="unknown"
# shellcheck source=detect-stack/detect-archetype.sh
source "${_detect_dir}/detect-archetype.sh"

# --- emit JSON ----------------------------------------------------------------

jq -n \
  --arg primary_language "$primary_language" \
  --argjson secondary_languages "$secondary_languages_json" \
  --argjson framework "$framework" \
  --argjson package_manager "$package_manager" \
  --argjson is_monorepo "$is_monorepo" \
  --argjson monorepo_tool "$monorepo_tool" \
  --argjson has_git "$has_git" \
  --argjson git_is_empty_repo "$git_is_empty_repo" \
  --argjson has_claude_md "$has_claude_md" \
  --arg existing_precommit_config "$existing_precommit_config" \
  --arg existing_ci "$existing_ci" \
  --argjson contributor_count "$contributor_count" \
  --argjson has_changelog "$has_changelog" \
  --argjson has_semver_tags "$has_semver_tags" \
  --argjson confidence "$confidence" \
  --arg reasoning_raw "$_reasons" \
  --argjson workspaces "$workspaces_json" \
  --arg archetype "$archetype" \
  '{
    primary_language: $primary_language,
    secondary_languages: $secondary_languages,
    framework: $framework,
    package_manager: $package_manager,
    is_monorepo: $is_monorepo,
    monorepo_tool: $monorepo_tool,
    has_git: $has_git,
    git_is_empty_repo: $git_is_empty_repo,
    has_claude_md: $has_claude_md,
    existing_precommit_config: $existing_precommit_config,
    existing_ci: $existing_ci,
    contributor_count: $contributor_count,
    has_changelog: $has_changelog,
    has_semver_tags: $has_semver_tags,
    archetype: $archetype,
    confidence: $confidence,
    reasoning: ($reasoning_raw | split("\n") | map(select(. != ""))),
    workspaces: $workspaces
  }'
