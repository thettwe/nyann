#!/usr/bin/env bash
# notify-deliver.sh — fan queued Notification entries out to the external
# delivery channels a user has opted into (Slack / Discord / generic
# webhook / email).
#
# Usage:
#   # production: pipe the queue reader straight in
#   read-notifications.sh --repo <owner/repo> | notify-deliver.sh --repo <owner/repo>
#
#   # standalone / test: feed a JSON array on stdin, override locations
#   notify-deliver.sh --repo <owner/repo> [--user-root <dir>] [--config <json>]
#                     [--cache-dir <dir>] [--channels-dir <dir>]  < batch.json
#
# Reads a JSON array of Notification objects on stdin and dispatches it to
# each channel marked enabled in preferences.json `notifications.delivery`
# (or the --config override). OPT-IN: if no channel is configured/enabled it
# is a silent no-op — no network, no files written. DEDUP: every delivered
# notification's content hash is recorded in a per-repo marker under the
# cache dir, so re-reading or re-running never sends the same entry twice.
#
# Channel scripts live in bin/notify-channels/ and each reads its secret
# endpoint from an environment variable named in preferences — never a
# literal URL from the file. Missing env vars / missing curl soft-skip with
# a warning; this orchestrator always exits 0 on a delivery attempt so it
# can be chained after the queue reader without breaking the pipeline.
#
# Requires jq.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

repo=""
user_root="${NYANN_USER_ROOT:-${HOME}/.claude/nyann}"
config_override=""
cache_dir=""
channels_dir="${_script_dir}/notify-channels"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          repo="${2-}"; shift 2 ;;
    --repo=*)        repo="${1#--repo=}"; shift ;;
    --user-root)     user_root="${2-}"; shift 2 ;;
    --user-root=*)   user_root="${1#--user-root=}"; shift ;;
    --config)        config_override="${2-}"; shift 2 ;;
    --config=*)      config_override="${1#--config=}"; shift ;;
    --cache-dir)     cache_dir="${2-}"; shift 2 ;;
    --cache-dir=*)   cache_dir="${1#--cache-dir=}"; shift ;;
    --channels-dir)  channels_dir="${2-}"; shift 2 ;;
    --channels-dir=*) channels_dir="${1#--channels-dir=}"; shift ;;
    -h|--help)       sed -n '3,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || nyann::die "--repo <owner/repo> is required"
[[ -n "$cache_dir" ]] || cache_dir="${user_root}/cache"

# --- Resolve the delivery config ---------------------------------------------
# Priority: explicit --config (tests / callers) > preferences.json. A missing
# file or absent block yields an empty object — i.e. nothing enabled.
delivery='{}'
if [[ -n "$config_override" ]]; then
  if ! delivery=$(jq -ce '.' <<<"$config_override" 2>/dev/null); then
    nyann::die "--config is not valid JSON"
  fi
elif [[ -f "${user_root}/preferences.json" ]]; then
  delivery=$(jq -c '.notifications.delivery // {}' "${user_root}/preferences.json" 2>/dev/null || echo '{}')
fi
# Guard against a non-object delivery block (corrupt prefs).
[[ "$(jq -r 'type' <<<"$delivery" 2>/dev/null || echo error)" == "object" ]] || delivery='{}'

# Short-circuit: nothing enabled → silent no-op, no stdin work, no network.
any_enabled=$(jq -r '[.slack.enabled, .discord.enabled, .webhook.enabled, .email.enabled]
                     | map(. == true) | any' <<<"$delivery" 2>/dev/null || echo false)
if [[ "$any_enabled" != "true" ]]; then
  exit 0
fi

# --- Read + validate the batch -----------------------------------------------
batch="$(cat)"
if [[ -z "${batch//[[:space:]]/}" ]]; then
  exit 0
fi
if [[ "$(jq -r 'type' <<<"$batch" 2>/dev/null || echo error)" != "array" ]]; then
  nyann::warn "notify-deliver: stdin is not a JSON array — nothing to deliver"
  exit 0
fi
total=$(jq 'length' <<<"$batch")
[[ "$total" -eq 0 ]] && exit 0

# --- Dedup against the per-repo delivered-marker -----------------------------
repo_hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-16)
marker="${cache_dir}/${repo_hash}.delivered"

hash_id() {
  printf '%s' "$1" | (md5sum 2>/dev/null || md5 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-16
}

new_elems=()
new_ids=()
for (( i = 0; i < total; i++ )); do
  elem=$(jq -c ".[$i]" <<<"$batch")
  id=$(hash_id "$elem")
  if [[ -f "$marker" ]] && grep -qxF "$id" "$marker" 2>/dev/null; then
    continue
  fi
  new_elems+=("$elem")
  new_ids+=("$id")
done

# Everything already delivered → no-op (this is the dedup guarantee).
if (( ${#new_elems[@]} == 0 )); then
  exit 0
fi

new_batch=$(printf '%s\n' "${new_elems[@]}" | jq -s '.')

# --- Fan out to each enabled channel -----------------------------------------
# Each channel reads the batch on stdin and resolves its secret endpoint from
# the named env var itself. A channel enabled but missing its env-var NAME (or
# email `to`) is skipped with a warning — never fatal.
slack_enabled=$(jq -r '.slack.enabled // false'   <<<"$delivery")
discord_enabled=$(jq -r '.discord.enabled // false' <<<"$delivery")
webhook_enabled=$(jq -r '.webhook.enabled // false' <<<"$delivery")
email_enabled=$(jq -r '.email.enabled // false'   <<<"$delivery")

if [[ "$slack_enabled" == "true" ]]; then
  env_name=$(jq -r '.slack.webhook_url_env // empty' <<<"$delivery")
  if [[ -n "$env_name" ]]; then
    printf '%s' "$new_batch" | bash "${channels_dir}/slack.sh" --env "$env_name" || nyann::warn "slack channel returned an error"
  else
    nyann::warn "slack channel enabled but webhook_url_env is unset — skipping"
  fi
fi

if [[ "$discord_enabled" == "true" ]]; then
  env_name=$(jq -r '.discord.webhook_url_env // empty' <<<"$delivery")
  if [[ -n "$env_name" ]]; then
    printf '%s' "$new_batch" | bash "${channels_dir}/discord.sh" --env "$env_name" || nyann::warn "discord channel returned an error"
  else
    nyann::warn "discord channel enabled but webhook_url_env is unset — skipping"
  fi
fi

if [[ "$webhook_enabled" == "true" ]]; then
  env_name=$(jq -r '.webhook.url_env // empty' <<<"$delivery")
  if [[ -n "$env_name" ]]; then
    printf '%s' "$new_batch" | bash "${channels_dir}/webhook.sh" --env "$env_name" || nyann::warn "webhook channel returned an error"
  else
    nyann::warn "webhook channel enabled but url_env is unset — skipping"
  fi
fi

if [[ "$email_enabled" == "true" ]]; then
  to=$(jq -r '.email.to // empty'       <<<"$delivery")
  from=$(jq -r '.email.from // empty'   <<<"$delivery")
  smtp_env=$(jq -r '.email.smtp_env // empty' <<<"$delivery")
  if [[ -n "$to" ]]; then
    args=(--to "$to")
    [[ -n "$from" ]]     && args+=(--from "$from")
    [[ -n "$smtp_env" ]] && args+=(--smtp-env "$smtp_env")
    printf '%s' "$new_batch" | bash "${channels_dir}/email.sh" "${args[@]}" || nyann::warn "email channel returned an error"
  else
    nyann::warn "email channel enabled but 'to' is unset — skipping"
  fi
fi

# --- Record the just-delivered IDs so they never resend ----------------------
# Append under the marker lock; cap the file so it can't grow unbounded across
# a long-lived repo. We mark after dispatch (best-effort delivery): the queue
# reader already truncates on read, so the marker is a belt-and-suspenders
# guard against the same content arriving twice.
mkdir -p "$cache_dir" 2>/dev/null || true
lock_dir="${marker}.lock"
nyann::lock "$lock_dir"
printf '%s\n' "${new_ids[@]}" >> "$marker" 2>/dev/null || true
if [[ -f "$marker" ]]; then
  tail -n 1000 "$marker" > "${marker}.trim" 2>/dev/null && mv "${marker}.trim" "$marker" 2>/dev/null || true
fi
nyann::unlock "$lock_dir"

exit 0
