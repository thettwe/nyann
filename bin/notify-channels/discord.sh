#!/usr/bin/env bash
# discord.sh — deliver a batch of Notification entries to a Discord
# webhook.
#
# Usage:
#   discord.sh --env <ENV_VAR_NAME>   < notifications.json
#
# Reads a JSON array of Notification objects on stdin and POSTs a Discord
# webhook payload ({content: ...}) to the URL held in the named environment
# variable. The webhook URL is read from the environment at delivery time via
# `printenv` (NEVER bash indirect expansion `${!name}`, which arithmetic-
# evaluates array subscripts and would run an attacker substring like
# `x[$(cmd)]` — RCE). <ENV_VAR_NAME> is validated to a POSIX identifier first.
#
# EXIT CONTRACT (shared with notify-deliver.sh): exit 0 ONLY on a confirmed
# delivery (curl --fail saw a 2xx). A soft-skip (unset env, missing curl,
# invalid env name) or a failed POST returns NON-ZERO (75 for soft-skip, or
# curl's own status) so the orchestrator leaves the notification UN-marked and
# retries it. Invoked by bin/notify-deliver.sh; not for direct user use.

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

# Validate the env-var NAME before resolving it — `${!name}` arithmetic-
# evaluates array subscripts (RCE via `x[$(cmd)]`); printenv does not.
if [[ ! "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  nyann::warn "discord: invalid env var name '$env_name' — skipping"
  exit 75
fi

if ! nyann::has_cmd curl; then
  nyann::warn "discord: curl not installed — skipping delivery"
  exit 75
fi

url="$(printenv -- "$env_name" 2>/dev/null || true)"
if [[ -z "$url" ]]; then
  nyann::warn "discord: env var \$${env_name} is unset — skipping (export it to enable Discord delivery)"
  exit 75
fi

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# Discord webhook shape: {content: "..."}. One line per notification. Prepend
# the repo tag (context.repo) so multi-repo aggregate delivery is unambiguous.
payload="$(jq -c '{content: ([.[] | "\(if .context.repo then "[\(.context.repo)] " else "" end)[\(.severity)] \(.message)"] | join("\n"))}' <<<"$batch")"

# Keep the (secret) webhook URL OFF argv (a Discord webhook URL embeds the
# token): write `url = "..."` to a 0600 mktemp config file and feed it to curl
# via `-K` instead of `--url "$url"`, so it never appears in `ps`/`/proc`. `-K`
# reads the URL like `--url` (and guards a leading `-`); the body travels on
# stdin via `--data-binary @-`. --fail → non-2xx is a non-zero exit; timeouts
# stop a hung endpoint wedging the loop. Return curl's status.
curl_conf="$(mktemp -t nyann-discord.XXXXXX)"
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
  nyann::warn "discord: delivery request failed (network or webhook error)"
fi
exit "$rc"
