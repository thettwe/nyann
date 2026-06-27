#!/usr/bin/env bash
# webhook.sh — deliver a batch of Notification entries to a generic
# webhook endpoint.
#
# Usage:
#   webhook.sh --env <ENV_VAR_NAME>   < notifications.json
#
# Reads a JSON array of Notification objects on stdin and POSTs that JSON
# array verbatim (Content-Type: application/json) to the URL held in the
# named environment variable. The URL is read from the environment at
# delivery time via `printenv` (NEVER bash indirect expansion `${!name}`,
# which arithmetic-evaluates array subscripts and would run an attacker
# substring like `x[$(cmd)]` — RCE). <ENV_VAR_NAME> is validated to a POSIX
# identifier first; the URL is never stored in preferences.json.
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
  nyann::warn "webhook: invalid env var name '$env_name' — skipping"
  exit 75
fi

if ! nyann::has_cmd curl; then
  nyann::warn "webhook: curl not installed — skipping delivery"
  exit 75
fi

url="$(printenv -- "$env_name" 2>/dev/null || true)"
if [[ -z "$url" ]]; then
  nyann::warn "webhook: env var \$${env_name} is unset — skipping (export it to enable webhook delivery)"
  exit 75
fi

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# Generic webhook: POST the raw notification array unchanged so downstream
# automation gets the full structured payload (repo identity travels in each
# entry's context.repo, tagged by notify-deliver). Compact it first.
payload="$(jq -c '.' <<<"$batch")"

# --fail → non-2xx is a non-zero exit; timeouts stop a hung endpoint wedging
# the loop; --url guards a URL beginning with `-`. Return curl's status.
rc=0
printf '%s' "$payload" \
  | curl --fail -sS --connect-timeout 5 --max-time 15 \
      -X POST -H 'Content-Type: application/json' --data-binary @- \
      --url "$url" >/dev/null 2>&1 || rc=$?
if (( rc != 0 )); then
  nyann::warn "webhook: delivery request failed (network or endpoint error)"
fi
exit "$rc"
