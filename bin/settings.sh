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
#   notifications.delivery.slack.enabled, .slack.webhook_url_env,
#   notifications.delivery.discord.enabled, .discord.webhook_url_env,
#   notifications.delivery.webhook.enabled, .webhook.url_env,
#   notifications.delivery.email.enabled, .email.to, .email.from,
#   .email.smtp_env
#
# SECURITY: the delivery *_env keys store the NAME of an environment
# variable that holds the secret endpoint (e.g. NYANN_SLACK_WEBHOOK), never
# a literal URL. --set REFUSES any value matching http(s):// for a delivery
# key so a token/URL can never land in preferences.json. Setting any
# delivery key upgrades the file to schemaVersion 3 (2→3) without losing
# existing values.
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
    --set)         mode="set"; set_key="${2:-}"; set_value="${3:-}"; shift "$(( $# < 3 ? $# : 3 ))" ;;
    --json)        json_out=true; shift ;;
    -h|--help)     sed -n '3,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
  # Booleans use explicit comparisons, never `// <default>`: jq's `//`
  # operator treats a literal `false` as null-equivalent, so a stored
  # `false` would be replaced by the fallback and a DISABLED feature would
  # render as enabled. Match what's on disk; fall back only when absent.
  printf '%-32s %s\n' "gh_integration"                  "$(jq -r 'if .gh_integration == false then "false" elif .gh_integration == true then "true" else "true" end' "$prefs_path")"
  printf '%-32s %s\n' "documentation_storage"           "$(jq -r '.documentation_storage // "local"' "$prefs_path")"
  printf '%-32s %s\n' "auto_sync_team_profiles"         "$(jq -r 'if .auto_sync_team_profiles == true then "true" elif .auto_sync_team_profiles == false then "false" else "false" end' "$prefs_path")"
  printf '%-32s %s\n' "session_triage"                  "$(jq -r 'if .session_triage == false then "false" elif .session_triage == true then "true" else "true" end' "$prefs_path")"
  printf '%-32s %s\n' "guard_default_severity"          "$(jq -r '.guard_default_severity // "advisory"' "$prefs_path")"
  printf '%-32s %s\n' "notifications.sentinel"          "$(jq -r 'if .notifications.sentinel == false then "false" elif .notifications.sentinel == true then "true" else "true" end' "$prefs_path")"
  printf '%-32s %s\n' "notifications.staleness_alerts"  "$(jq -r 'if .notifications.staleness_alerts == false then "false" elif .notifications.staleness_alerts == true then "true" else "true" end' "$prefs_path")"
  printf '%-32s %s <%s>\n' "git_identity (name <email>)" \
    "$(jq -r '.git_identity.name // ""'  "$prefs_path")" \
    "$(jq -r '.git_identity.email // ""' "$prefs_path")"
  # Notification delivery channels (opt-in, schemaVersion 3). Show the
  # enabled flag and the env-var NAME each channel reads its endpoint from
  # (never the secret itself). Absent → "off" / "(unset)".
  for ch in slack discord webhook email; do
    case "$ch" in
      slack|discord) envk="webhook_url_env" ;;
      webhook)       envk="url_env" ;;
      email)         envk="smtp_env" ;;
    esac
    en=$(jq -r --arg ch "$ch" 'if .notifications.delivery[$ch].enabled == true then "on" else "off" end' "$prefs_path")
    ev=$(jq -r --arg ch "$ch" --arg k "$envk" '.notifications.delivery[$ch][$k] // "(unset)"' "$prefs_path")
    printf '%-32s %s (%s=%s)\n' "delivery.$ch" "$en" "$envk" "$ev"
  done
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
  notifications.delivery.slack.enabled|notifications.delivery.discord.enabled|notifications.delivery.webhook.enabled|notifications.delivery.email.enabled)
    case "$set_value" in true|false) ;;
      *) nyann::die "invalid value for $set_key: $set_value (expected true|false)" ;;
    esac
    ;;
  notifications.delivery.slack.webhook_url_env|notifications.delivery.discord.webhook_url_env|notifications.delivery.webhook.url_env|notifications.delivery.email.smtp_env)
    # SECURITY: delivery endpoints are secrets. We store only the NAME of an
    # environment variable that holds the URL — never the URL itself — so a
    # token can't leak into preferences.json (which may be synced/backed up).
    # Refuse anything that looks like a literal URL and require a valid POSIX
    # env-var name.
    if [[ "$set_value" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]]; then
      nyann::die "refusing to store a literal URL in $set_key. Store the NAME of an environment variable that holds the URL (e.g. NYANN_SLACK_WEBHOOK), not the URL itself — nyann reads the secret from that env var at delivery time so it never touches preferences.json."
    fi
    [[ "$set_value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || nyann::die "invalid env var name for $set_key: $set_value (expected an environment variable name like NYANN_SLACK_WEBHOOK, matching [A-Za-z_][A-Za-z0-9_]*)"
    ;;
  notifications.delivery.email.to|notifications.delivery.email.from)
    if [[ "$set_value" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]]; then
      nyann::die "refusing to store a URL in $set_key — expected a plain email address."
    fi
    # Reject CR/LF: these addresses are written verbatim into RFC822 To/From
    # headers by email.sh, so a newline would inject extra headers (or a body)
    # — classic email header injection. email.sh also strips CR/LF at the read
    # site; rejecting here keeps the stored value clean in the first place.
    if [[ "$set_value" == *$'\n'* || "$set_value" == *$'\r'* ]]; then
      nyann::die "invalid value for $set_key: must not contain CR/LF (email header injection)"
    fi
    [[ -n "$set_value" ]] || nyann::die "invalid value for $set_key: empty"
    ;;
  *)
    nyann::die "unknown key: $set_key"
    ;;
esac

# Coerce booleans for jq.
case "$set_key" in
  gh_integration|auto_sync_team_profiles|session_triage|notifications.sentinel|notifications.staleness_alerts|git_identity.confirmed|notifications.delivery.slack.enabled|notifications.delivery.discord.enabled|notifications.delivery.webhook.enabled|notifications.delivery.email.enabled)
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
# schemaVersion writes use `max(existing, floor)` so a touch never DOWNGRADES
# a file: a v3 prefs (delivery configured) keeps v3 when an unrelated key is
# set. Non-delivery keys floor at 2 (the pre-delivery current schema);
# delivery keys floor at 3 (the 2→3 upgrade — existing values are preserved
# by the setpath merge below).
case "$set_key" in
  notifications.delivery.*)
    # Build the jq path array from the dotted key and merge via setpath so
    # sibling channels and notifications.{sentinel,staleness_alerts} survive.
    path_json=$(printf '%s' "$set_key" | jq -R 'split(".")')
    jq "$jq_arg" v "$jq_value" --argjson path "$path_json" \
      'setpath($path; $v) | .schemaVersion = ([.schemaVersion // 1, 3] | max)' \
      "$prefs_path" > "$tmp"
    ;;
  notifications.sentinel|notifications.staleness_alerts)
    sub="${set_key#notifications.}"
    jq "$jq_arg" v "$jq_value" --arg sub "$sub" \
      '.notifications = ((.notifications // {}) | .[$sub] = $v) | .schemaVersion = ([.schemaVersion // 1, 2] | max)' \
      "$prefs_path" > "$tmp"
    ;;
  git_identity.name|git_identity.email|git_identity.confirmed)
    sub="${set_key#git_identity.}"
    jq "$jq_arg" v "$jq_value" --arg sub "$sub" \
      '.git_identity = ((.git_identity // {}) | .[$sub] = $v) | .schemaVersion = ([.schemaVersion // 1, 2] | max)' \
      "$prefs_path" > "$tmp"
    ;;
  *)
    jq "$jq_arg" v "$jq_value" --arg key "$set_key" \
      '.[$key] = $v | .schemaVersion = ([.schemaVersion // 1, 2] | max)' \
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
