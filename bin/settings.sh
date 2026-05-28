#!/usr/bin/env bash
# settings.sh — viewer/editor for ~/.claude/nyann/preferences.json.
#
# Usage:
#   settings.sh [--show]                 # display all settings (default)
#   settings.sh --set <key> <value>      # update one field, preserve rest
#   settings.sh --json                   # raw JSON (programmatic access)
#   settings.sh --user-root <dir>        # override location (testing)
#
# Supported keys for --set:
#   default_profile, branching_strategy, commit_format, gh_integration,
#   documentation_storage, auto_sync_team_profiles, session_triage,
#   guard_default_severity, notifications.sentinel,
#   notifications.staleness_alerts, git_identity.name, git_identity.email,
#   git_identity.confirmed
#
# Designed for the /nyann:settings interactive menu: the skill calls
# `--show --json` to render the table, then `--set <k> <v>` after each
# AskUserQuestion pick. Pure shell; no LLM dependency.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

user_root="${HOME}/.claude/nyann"
mode="show"
json_out=false
set_key=""
set_value=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    --show)        mode="show"; shift ;;
    --set)         mode="set"; set_key="${2:-}"; set_value="${3:-}"; shift 3 ;;
    --json)        json_out=true; shift ;;
    -h|--help)     sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             nyann::die "unknown argument: $1" ;;
  esac
done

prefs_path="${user_root}/preferences.json"
[[ -f "$prefs_path" ]] || nyann::die "preferences not found at $prefs_path — run /nyann:setup first"

# --- Show mode ----------------------------------------------------------------

if [[ "$mode" == "show" ]]; then
  if $json_out; then
    cat "$prefs_path"
    exit 0
  fi
  printf '\nCurrent nyann preferences:\n\n'
  printf '%-32s %s\n' "default_profile"                 "$(jq -r '.default_profile // "auto-detect"' "$prefs_path")"
  printf '%-32s %s\n' "branching_strategy"              "$(jq -r '.branching_strategy // "auto-detect"' "$prefs_path")"
  printf '%-32s %s\n' "commit_format"                   "$(jq -r '.commit_format // "conventional-commits"' "$prefs_path")"
  printf '%-32s %s\n' "gh_integration"                  "$(jq -r '.gh_integration // true' "$prefs_path")"
  printf '%-32s %s\n' "documentation_storage"           "$(jq -r '.documentation_storage // "local"' "$prefs_path")"
  printf '%-32s %s\n' "auto_sync_team_profiles"         "$(jq -r '.auto_sync_team_profiles // false' "$prefs_path")"
  printf '%-32s %s\n' "session_triage"                  "$(jq -r '.session_triage // true' "$prefs_path")"
  printf '%-32s %s\n' "guard_default_severity"          "$(jq -r '.guard_default_severity // "advisory"' "$prefs_path")"
  printf '%-32s %s\n' "notifications.sentinel"          "$(jq -r '.notifications.sentinel // true' "$prefs_path")"
  printf '%-32s %s\n' "notifications.staleness_alerts"  "$(jq -r '.notifications.staleness_alerts // true' "$prefs_path")"
  printf '%-32s %s <%s>\n' "git_identity (name <email>)" \
    "$(jq -r '.git_identity.name // ""'  "$prefs_path")" \
    "$(jq -r '.git_identity.email // ""' "$prefs_path")"
  printf '\nTo update one: bin/settings.sh --set <key> <value>\n'
  exit 0
fi

# --- Set mode -----------------------------------------------------------------

[[ -n "$set_key" ]]   || nyann::die "--set requires a <key>"
[[ -n "$set_value" ]] || nyann::die "--set requires a <value>"

# Validate value per key. Keep this list aligned with the schema enums.
case "$set_key" in
  default_profile)
    [[ "$set_value" == "auto-detect" || "$set_value" =~ ^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)?$ ]] \
      || nyann::die "invalid value for $set_key: $set_value"
    ;;
  branching_strategy)
    case "$set_value" in auto-detect|github-flow|gitflow|trunk-based) ;;
      *) nyann::die "invalid value for $set_key: $set_value (expected auto-detect|github-flow|gitflow|trunk-based)" ;;
    esac
    ;;
  commit_format)
    case "$set_value" in conventional-commits|custom) ;;
      *) nyann::die "invalid value for $set_key: $set_value (expected conventional-commits|custom)" ;;
    esac
    ;;
  gh_integration|auto_sync_team_profiles|session_triage|notifications.sentinel|notifications.staleness_alerts|git_identity.confirmed)
    case "$set_value" in true|false) ;;
      *) nyann::die "invalid value for $set_key: $set_value (expected true|false)" ;;
    esac
    ;;
  documentation_storage)
    case "$set_value" in local|obsidian|notion) ;;
      *) nyann::die "invalid value for $set_key: $set_value (expected local|obsidian|notion)" ;;
    esac
    ;;
  guard_default_severity)
    case "$set_value" in advisory|confirm) ;;
      *) nyann::die "invalid value for $set_key: $set_value (expected advisory|confirm)" ;;
    esac
    ;;
  git_identity.name|git_identity.email)
    [[ -n "$set_value" ]] || nyann::die "invalid value for $set_key: empty"
    ;;
  *)
    nyann::die "unknown key: $set_key"
    ;;
esac

# Coerce booleans for jq.
case "$set_key" in
  gh_integration|auto_sync_team_profiles|session_triage|notifications.sentinel|notifications.staleness_alerts|git_identity.confirmed)
    jq_value="$set_value"  # raw true/false
    jq_arg="--argjson"
    ;;
  *)
    jq_value="$set_value"
    jq_arg="--arg"
    ;;
esac

tmp=$(mktemp -t nyann-prefs.XXXXXX)
trap 'rm -f "$tmp"' EXIT

# Build the assignment path. For nested keys (notifications.X, git_identity.X)
# we expand to a jq object-merge so the parent object stays well-formed even
# when it's missing in the source file.
case "$set_key" in
  notifications.sentinel|notifications.staleness_alerts)
    sub="${set_key#notifications.}"
    jq "$jq_arg" v "$jq_value" --arg sub "$sub" \
      '.notifications = ((.notifications // {}) | .[$sub] = $v) | .schemaVersion = 2' \
      "$prefs_path" > "$tmp"
    ;;
  git_identity.name|git_identity.email|git_identity.confirmed)
    sub="${set_key#git_identity.}"
    jq "$jq_arg" v "$jq_value" --arg sub "$sub" \
      '.git_identity = ((.git_identity // {}) | .[$sub] = $v) | .schemaVersion = 2' \
      "$prefs_path" > "$tmp"
    ;;
  *)
    jq "$jq_arg" v "$jq_value" --arg key "$set_key" \
      '.[$key] = $v | .schemaVersion = 2' \
      "$prefs_path" > "$tmp"
    ;;
esac

[[ -L "$prefs_path" ]] && nyann::die "refusing to write preferences via symlink: $prefs_path"
mv "$tmp" "$prefs_path"
chmod 600 "$prefs_path" 2>/dev/null || true

if $json_out; then
  cat "$prefs_path"
else
  printf '[nyann] updated %s = %s\n' "$set_key" "$set_value"
fi
