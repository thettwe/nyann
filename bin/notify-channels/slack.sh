#!/usr/bin/env bash
# slack.sh — deliver a batch of Notification entries to a Slack incoming
# webhook.
#
# Usage:
#   slack.sh --env <ENV_VAR_NAME>   < notifications.json
#
# Reads a JSON array of Notification objects on stdin and POSTs a Slack
# incoming-webhook payload ({text: ...}) to the URL held in the named
# environment variable. The webhook URL is read from the environment at
# delivery time (indirect expansion of <ENV_VAR_NAME>) — never passed on
# the command line and never stored in preferences.json. Missing env var
# or missing curl → warn + skip (exit 0), never crash. Invoked by
# bin/notify-deliver.sh; not meant to be called directly by users.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

env_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     env_name="${2-}"; shift 2 ;;
    --env=*)   env_name="${1#--env=}"; shift ;;
    -h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$env_name" ]] || nyann::die "--env <ENV_VAR_NAME> is required"

# Soft-skip when curl is unavailable — delivery is best-effort, never fatal.
if ! nyann::has_cmd curl; then
  nyann::warn "slack: curl not installed — skipping delivery"
  exit 0
fi

# Resolve the endpoint from the environment by NAME (indirect expansion).
# An unset/empty env var means the user named a channel but never exported
# the secret — skip with a hint rather than crashing the whole fan-out.
url="${!env_name-}"
if [[ -z "$url" ]]; then
  nyann::warn "slack: env var \$${env_name} is unset — skipping (export it to enable Slack delivery)"
  exit 0
fi

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
# Nothing to send for an empty array.
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# Slack incoming-webhook shape: {text: "..."}. One line per notification.
payload="$(jq -c '{text: ([.[] | "[\(.severity)] \(.message)"] | join("\n"))}' <<<"$batch")"

# Send the body via stdin so the (secret) URL stays the only argv item and
# the payload never appears in `ps`. Best-effort: warn on failure, exit 0.
if ! printf '%s' "$payload" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- "$url" >/dev/null 2>&1; then
  nyann::warn "slack: delivery request failed (network or webhook error)"
fi
exit 0
