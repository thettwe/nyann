#!/usr/bin/env bash
# discord.sh — deliver a batch of Notification entries to a Discord
# webhook.
#
# Usage:
#   discord.sh --env <ENV_VAR_NAME>   < notifications.json
#
# Reads a JSON array of Notification objects on stdin and POSTs a Discord
# webhook payload ({content: ...}) to the URL held in the named environment
# variable. The webhook URL is read from the environment at delivery time
# (indirect expansion of <ENV_VAR_NAME>) — never passed on the command line
# and never stored in preferences.json. Missing env var or missing curl →
# warn + skip (exit 0), never crash. Invoked by bin/notify-deliver.sh; not
# meant to be called directly by users.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

env_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     env_name="${2-}"; shift 2 ;;
    --env=*)   env_name="${1#--env=}"; shift ;;
    -h|--help) sed -n '3,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$env_name" ]] || nyann::die "--env <ENV_VAR_NAME> is required"

if ! nyann::has_cmd curl; then
  nyann::warn "discord: curl not installed — skipping delivery"
  exit 0
fi

url="${!env_name-}"
if [[ -z "$url" ]]; then
  nyann::warn "discord: env var \$${env_name} is unset — skipping (export it to enable Discord delivery)"
  exit 0
fi

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# Discord webhook shape: {content: "..."}. One line per notification.
payload="$(jq -c '{content: ([.[] | "[\(.severity)] \(.message)"] | join("\n"))}' <<<"$batch")"

if ! printf '%s' "$payload" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- "$url" >/dev/null 2>&1; then
  nyann::warn "discord: delivery request failed (network or webhook error)"
fi
exit 0
