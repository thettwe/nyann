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
# delivery time via `printenv` (NEVER bash indirect expansion `${!name}`,
# which evaluates array subscripts as arithmetic and would run an attacker
# substring like `x[$(cmd)]` — RCE). <ENV_VAR_NAME> is validated to a POSIX
# identifier first. The URL never reaches argv via `${...}` and is never
# stored in preferences.json.
#
# EXIT CONTRACT (shared with notify-deliver.sh): exit 0 ONLY on a confirmed
# delivery (curl --fail saw a 2xx). A soft-skip (unset env, missing curl,
# invalid env name) or a failed POST returns NON-ZERO (75 for soft-skip, or
# curl's own status for a transport/HTTP failure) so the orchestrator leaves
# the notification UN-marked and retries it next poll. Invoked by
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

# Validate the env-var NAME before resolving it. `${!name}` (indirect
# expansion) treats `name` as `arr[subscript]` and arithmetic-evaluates the
# subscript, so a value like `x[$(touch pwned)]` runs the command — RCE. A
# strict POSIX-identifier check plus `printenv` (which does NOT evaluate
# subscripts) closes that hole. Soft-skip (75) rather than crash the fan-out.
if [[ ! "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  nyann::warn "slack: invalid env var name '$env_name' — skipping"
  exit 75
fi

# Soft-skip when curl is unavailable — delivery is best-effort, never fatal.
if ! nyann::has_cmd curl; then
  nyann::warn "slack: curl not installed — skipping delivery"
  exit 75
fi

# Resolve the endpoint from the environment by NAME via printenv (never
# `${!env_name}`). An unset/empty env var means the user named a channel but
# never exported the secret — skip with a hint rather than crashing.
url="$(printenv -- "$env_name" 2>/dev/null || true)"
if [[ -z "$url" ]]; then
  nyann::warn "slack: env var \$${env_name} is unset — skipping (export it to enable Slack delivery)"
  exit 75
fi

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
# Nothing to send for an empty array.
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# Slack incoming-webhook shape: {text: "..."}. One line per notification.
# Prepend the repo tag (context.repo, set by notify-deliver) so a multi-repo
# aggregate delivery says which repo each line is from.
payload="$(jq -c '{text: ([.[] | "\(if .context.repo then "[\(.context.repo)] " else "" end)[\(.severity)] \(.message)"] | join("\n"))}' <<<"$batch")"

# Keep the (secret) webhook URL OFF argv: the incoming-webhook URL embeds the
# auth token, so a `--url "$url"` would expose it to `ps`/`/proc` for the
# request lifetime. Mirror email.sh — write `url = "..."` to a 0600 mktemp
# config file and feed it to curl via `-K`, which reads the URL exactly like
# `--url` (and still guards a URL beginning with `-`). The body travels on
# stdin via `--data-binary @-`, which composes with `-K`. `--fail` turns a
# non-2xx into a non-zero exit; the timeouts stop a hung endpoint from wedging
# the poll loop. Return curl's status: exit 0 ONLY on confirmed delivery.
curl_conf="$(mktemp -t nyann-slack.XXXXXX)"
trap 'rm -f "$curl_conf"' EXIT
( umask 077; printf 'url = "%s"\n' "$url" > "$curl_conf" )
rc=0
printf '%s' "$payload" \
  | curl --fail -sS --connect-timeout 5 --max-time 15 -K "$curl_conf" \
      -X POST -H 'Content-Type: application/json' --data-binary @- \
      >/dev/null 2>&1 || rc=$?
rm -f "$curl_conf"
trap - EXIT
if (( rc != 0 )); then
  nyann::warn "slack: delivery request failed (network or webhook error)"
fi
exit "$rc"
