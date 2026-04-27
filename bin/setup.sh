#!/usr/bin/env bash
# setup.sh — create the nyann user directory structure and write preferences.
#
# Usage: setup.sh [options]
#
# Options:
#   --user-root <dir>            Override ~/.claude/nyann (testing)
#   --default-profile <name>     Default profile (default: auto-detect)
#   --branching-strategy <s>     auto-detect|github-flow|gitflow|trunk-based
#   --commit-format <f>          conventional-commits|custom
#   --gh-integration             Enable GitHub CLI integration (default)
#   --no-gh-integration          Disable GitHub CLI integration
#   --documentation-storage <s>  local|obsidian|notion
#   --auto-sync-team-profiles    Auto-sync team sources during bootstrap
#   --no-auto-sync-team-profiles Disable auto-sync (default)
#   --json                       Emit result as JSON instead of human table
#   --check                      Report current state without writing anything
#
# Exit codes:
#   0 — setup completed (or --check: preferences exist)
#   1 — hard error (missing jq, bad input)
#   2 — --check: no preferences.json found yet

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

user_root="${HOME}/.claude/nyann"
json_out=false
check_only=false

default_profile="auto-detect"
branching_strategy="auto-detect"
commit_format="conventional-commits"
gh_integration=true
documentation_storage="local"
auto_sync_team_profiles=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)                  user_root="${2:-}"; shift 2 ;;
    --user-root=*)                user_root="${1#--user-root=}"; shift ;;
    --default-profile)            default_profile="${2:-}"; shift 2 ;;
    --default-profile=*)          default_profile="${1#--default-profile=}"; shift ;;
    --branching-strategy)         branching_strategy="${2:-}"; shift 2 ;;
    --branching-strategy=*)       branching_strategy="${1#--branching-strategy=}"; shift ;;
    --commit-format)              commit_format="${2:-}"; shift 2 ;;
    --commit-format=*)            commit_format="${1#--commit-format=}"; shift ;;
    --gh-integration)             gh_integration=true; shift ;;
    --no-gh-integration)          gh_integration=false; shift ;;
    --documentation-storage)      documentation_storage="${2:-}"; shift 2 ;;
    --documentation-storage=*)    documentation_storage="${1#--documentation-storage=}"; shift ;;
    --auto-sync-team-profiles)    auto_sync_team_profiles=true; shift ;;
    --no-auto-sync-team-profiles) auto_sync_team_profiles=false; shift ;;
    --json)                       json_out=true; shift ;;
    --check)                      check_only=true; shift ;;
    -h|--help)                    sed -n '3,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                            nyann::die "unknown argument: $1" ;;
  esac
done

# --- Validation ---------------------------------------------------------------

case "$branching_strategy" in
  auto-detect|github-flow|gitflow|trunk-based) ;;
  *) nyann::die "invalid --branching-strategy: $branching_strategy (expected auto-detect|github-flow|gitflow|trunk-based)" ;;
esac

case "$commit_format" in
  conventional-commits|custom) ;;
  *) nyann::die "invalid --commit-format: $commit_format (expected conventional-commits|custom)" ;;
esac

case "$documentation_storage" in
  local|obsidian|notion) ;;
  *) nyann::die "invalid --documentation-storage: $documentation_storage (expected local|obsidian|notion)" ;;
esac

if [[ "$default_profile" != "auto-detect" ]]; then
  if ! [[ "$default_profile" =~ ^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)?$ ]]; then
    nyann::die "invalid --default-profile: $default_profile (must be 'auto-detect' or a valid profile name)"
  fi
fi

# --- Check mode ---------------------------------------------------------------

prefs_path="${user_root}/preferences.json"

if $check_only; then
  if [[ ! -f "$prefs_path" ]]; then
    if $json_out; then
      jq -n '{"status":"not_configured","preferences_path":$p,"user_root":$r,"directories":{"profiles":($r+"/profiles"),"cache":($r+"/cache")}}' \
        --arg p "$prefs_path" --arg r "$user_root"
    else
      printf '\nnyann setup status: not configured\n\n'
      printf '  preferences file:  %s (not found)\n' "$prefs_path"
      printf '  user root:         %s\n' "$user_root"
      printf '\nRun /nyann:setup to configure.\n'
    fi
    exit 0
  fi

  existing=$(cat "$prefs_path")
  dirs_ok=true
  [[ -d "${user_root}/profiles" ]] || dirs_ok=false
  [[ -d "${user_root}/cache" ]] || dirs_ok=false

  if $json_out; then
    jq -n --argjson prefs "$existing" --argjson dirs_ok "$dirs_ok" \
      '{"status":"configured","preferences":$prefs,"directories_ok":$dirs_ok}'
  else
    printf '\nnyann setup status: configured\n\n'
    printf '  %-26s %s\n' "default_profile:" "$(jq -r '.default_profile // "auto-detect"' <<<"$existing")"
    printf '  %-26s %s\n' "branching_strategy:" "$(jq -r '.branching_strategy // "auto-detect"' <<<"$existing")"
    printf '  %-26s %s\n' "commit_format:" "$(jq -r '.commit_format // "conventional-commits"' <<<"$existing")"
    printf '  %-26s %s\n' "gh_integration:" "$(jq -r '.gh_integration // true' <<<"$existing")"
    printf '  %-26s %s\n' "documentation_storage:" "$(jq -r '.documentation_storage // "local"' <<<"$existing")"
    printf '  %-26s %s\n' "auto_sync_team_profiles:" "$(jq -r '.auto_sync_team_profiles // false' <<<"$existing")"
    printf '  %-26s %s\n' "setup_completed_at:" "$(jq -r '.setup_completed_at // "unknown"' <<<"$existing")"
    printf '\n  directories ok:  %s\n' "$dirs_ok"
  fi
  exit 0
fi

# --- Create directory structure -----------------------------------------------

old_umask=$(umask)
umask 0077

mkdir -p "${user_root}/profiles" 2>/dev/null || true
mkdir -p "${user_root}/cache" 2>/dev/null || true

umask "$old_umask"

# --- Write preferences --------------------------------------------------------

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

prefs_tmp=$(mktemp -t nyann-prefs.XXXXXX)
trap 'rm -f "$prefs_tmp"' EXIT

jq -n \
  --argjson schema_version 1 \
  --arg default_profile "$default_profile" \
  --arg branching_strategy "$branching_strategy" \
  --arg commit_format "$commit_format" \
  --argjson gh_integration "$gh_integration" \
  --arg documentation_storage "$documentation_storage" \
  --argjson auto_sync_team_profiles "$auto_sync_team_profiles" \
  --arg setup_completed_at "$timestamp" \
  '{
    schemaVersion: $schema_version,
    default_profile: $default_profile,
    branching_strategy: $branching_strategy,
    commit_format: $commit_format,
    gh_integration: $gh_integration,
    documentation_storage: $documentation_storage,
    auto_sync_team_profiles: $auto_sync_team_profiles,
    setup_completed_at: $setup_completed_at
  }' > "$prefs_tmp"

[[ -L "$prefs_path" ]] && nyann::die "refusing to write preferences via symlink: $prefs_path"
mv "$prefs_tmp" "$prefs_path"

chmod 600 "$prefs_path" 2>/dev/null || true

$json_out || nyann::log "preferences written to ${prefs_path}"

# --- Output -------------------------------------------------------------------

if $json_out; then
  jq -n \
    --arg prefs_path "$prefs_path" \
    --arg user_root "$user_root" \
    --slurpfile prefs "$prefs_path" \
    '{
      status: "ok",
      preferences_path: $prefs_path,
      user_root: $user_root,
      preferences: $prefs[0],
      directories: {
        profiles: ($user_root + "/profiles"),
        cache: ($user_root + "/cache")
      }
    }'
else
  printf '\nnyann setup complete\n\n'
  printf '  %-26s %s\n' "preferences:" "$prefs_path"
  printf '  %-26s %s\n' "profiles dir:" "${user_root}/profiles"
  printf '  %-26s %s\n' "cache dir:" "${user_root}/cache"
  printf '\n  Preferences:\n'
  printf '  %-26s %s\n' "default_profile:" "$default_profile"
  printf '  %-26s %s\n' "branching_strategy:" "$branching_strategy"
  printf '  %-26s %s\n' "commit_format:" "$commit_format"
  printf '  %-26s %s\n' "gh_integration:" "$gh_integration"
  printf '  %-26s %s\n' "documentation_storage:" "$documentation_storage"
  printf '  %-26s %s\n' "auto_sync_team_profiles:" "$auto_sync_team_profiles"
fi
