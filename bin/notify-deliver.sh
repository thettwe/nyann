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
# is a silent no-op — no network, no files written.
#
# DEDUP (correct-by-construction, PER CHANNEL): each enabled channel dedups
# against its OWN marker (<repo-hash>.<channel>.delivered). A content hash is
# recorded in a channel's marker ONLY once THAT channel CONFIRMS delivery (exit
# 0); a soft-skip (unset env / missing curl) or a failed POST leaves the id
# UN-marked for that channel so ONLY that channel retries it next poll — a
# sibling channel's success or failure never affects it. The queue reader feeds
# us via `--peek` (non-draining), so a prematurely-marked id would otherwise be
# suppressed FOREVER; per-channel markers avoid the cross-channel drop that a
# single shared marker caused. Each marker is rewritten to `(ids that channel
# delivered this run) ∪ (existing-channel-marker ids ∩ current-batch ids)`:
# bounded to the live queue (no fixed cap to re-deliver past), never drops a
# still-queued id, never re-sends a delivered one.
#
# LOCKING: a channel's marker lock is held ONLY around its dedup scan and its
# post-delivery record — NEVER across the network send. The scan + record are
# each individually atomic; holding the lock across the (up to ~15s/channel)
# curl would let a hung channel wedge concurrent same-repo runs and could
# strand the lock past a kill, silently stalling delivery.
#
# Channel scripts live in bin/notify-channels/ and each reads its secret
# endpoint from an environment variable named in preferences — never a
# literal URL from the file, and resolved via `printenv` not `${!name}` (which
# would arithmetic-eval an `x[$(cmd)]` subscript → RCE). The *_env NAMEs are
# re-validated here too (defense in depth). This orchestrator always exits 0
# so it can be chained after the queue reader without breaking the pipeline.
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

# --- Per-channel dedup against per-channel delivered-markers -----------------
repo_hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-16)

hash_id() {
  printf '%s' "$1" | (md5sum 2>/dev/null || md5 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-16
}

# valid_env_name <name> — strict POSIX identifier. A delivery *_env value that
# fails this must never reach a channel's resolver (defense in depth against
# the `${!name}` arithmetic-subscript RCE, even though the channel re-checks).
valid_env_name() { [[ "${1-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

mkdir -p "$cache_dir" 2>/dev/null || true

# Hash every batch entry ONCE on the UNTAGGED element (stable id, identical
# scheme across runs). batch_ids[i] is the id of batch_elems[i]; batch_ids as a
# whole is the live-queue id set used to bound every rewritten channel marker.
batch_ids=()
batch_elems=()
for (( i = 0; i < total; i++ )); do
  elem=$(jq -c ".[$i]" <<<"$batch")
  batch_elems+=("$elem")
  batch_ids+=("$(hash_id "$elem")")
done

# channel_marker <channel> — path of the per-channel delivered-marker.
channel_marker() { printf '%s' "${cache_dir}/${repo_hash}.$1.delivered"; }

# scan_channel <channel> — under the channel marker's lock, populate the global
# NEW_IDX with the batch indices NOT yet recorded for this channel, then RELEASE
# the lock. No network is performed while the lock is held.
NEW_IDX=()
scan_channel() {
  local channel="$1" marker lock i
  marker="$(channel_marker "$channel")"
  lock="${marker}.lock"
  NEW_IDX=()
  nyann::lock "$lock"
  trap 'nyann::unlock "$lock"' EXIT
  for (( i = 0; i < total; i++ )); do
    if [[ -f "$marker" ]] && grep -qxF "${batch_ids[$i]}" "$marker" 2>/dev/null; then
      continue
    fi
    NEW_IDX+=("$i")
  done
  nyann::unlock "$lock"
  trap - EXIT
}

# record_channel <channel> [delivered_id...] — re-acquire the channel lock and
# rewrite its marker to `(delivered ids this run) ∪ (existing-marker ∩ batch_ids)`,
# bounded to the live queue. Called with NO delivered ids it simply PRUNES the
# marker to the live queue (the fully-up-to-date fast path). The lock is held
# only for this atomic record, never across the network.
record_channel() {
  local channel="$1"; shift
  local marker lock
  marker="$(channel_marker "$channel")"
  lock="${marker}.lock"
  local tmp_ids="${marker}.batchids.$$" tmp_keep="${marker}.keep.$$" tmp_out="${marker}.rewrite.$$"
  nyann::lock "$lock"
  trap 'nyann::unlock "$lock"' EXIT
  : > "$tmp_keep" 2>/dev/null || true
  printf '%s\n' "${batch_ids[@]}" > "$tmp_ids" 2>/dev/null || true
  # existing-marker ids still present in the current batch
  [[ -f "$marker" ]] && grep -xF -f "$tmp_ids" "$marker" >> "$tmp_keep" 2>/dev/null || true
  # ids this channel confirmed delivered this run
  if (( $# > 0 )); then
    printf '%s\n' "$@" >> "$tmp_keep" 2>/dev/null || true
  fi
  sort -u "$tmp_keep" > "$tmp_out" 2>/dev/null || true
  mv "$tmp_out" "$marker" 2>/dev/null || true
  rm -f "$tmp_ids" "$tmp_keep" 2>/dev/null || true
  nyann::unlock "$lock"
  trap - EXIT
}

# build_new_batch — emit the repo-tagged JSON array for the entries at NEW_IDX.
# Tagging mirrors read-notifications.sh --all; the dedup id was hashed on the
# UNTAGGED element so tagging here can't perturb dedup across runs.
build_new_batch() {
  local elems=() i
  for i in "${NEW_IDX[@]}"; do elems+=("${batch_elems[$i]}"); done
  printf '%s\n' "${elems[@]}" | jq -s --arg r "$repo" 'map(.context = ((.context // {}) + {repo: $r}))'
}

# deliver_channel <channel> <send-cmd...> — full per-channel cycle: scan under
# the channel lock (NEW_IDX), then OUTSIDE any lock build the repo-tagged batch
# and run <send-cmd> with it on stdin; on a confirmed send (exit 0) record those
# ids under the channel marker. A soft-skip/failure records nothing, so ONLY
# this channel retries. When the channel is already up to date, prune its marker
# to the live queue and skip the network entirely.
deliver_channel() {
  local channel="$1"; shift
  scan_channel "$channel"
  if (( ${#NEW_IDX[@]} == 0 )); then
    record_channel "$channel"
    return 0
  fi
  local nb ids=() i
  nb="$(build_new_batch)"
  if printf '%s' "$nb" | "$@"; then
    for i in "${NEW_IDX[@]}"; do ids+=("${batch_ids[$i]}"); done
    record_channel "$channel" "${ids[@]}"
  fi
}

# --- Fan out to each enabled channel -----------------------------------------
# Each channel reads the batch on stdin and resolves its secret endpoint from
# the named env var itself. A channel enabled but missing/invalid its env-var
# NAME (or email `to`) is skipped with a warning — never fatal. Dedup + record
# are PER CHANNEL (deliver_channel), so a soft-skip/failure on one channel never
# suppresses retry on it, and a sibling's success never marks it delivered.
slack_enabled=$(jq -r '.slack.enabled // false'   <<<"$delivery")
discord_enabled=$(jq -r '.discord.enabled // false' <<<"$delivery")
webhook_enabled=$(jq -r '.webhook.enabled // false' <<<"$delivery")
email_enabled=$(jq -r '.email.enabled // false'   <<<"$delivery")

if [[ "$slack_enabled" == "true" ]]; then
  env_name=$(jq -r '.slack.webhook_url_env // empty' <<<"$delivery")
  if [[ -z "$env_name" ]]; then
    nyann::warn "slack channel enabled but webhook_url_env is unset — skipping"
  elif ! valid_env_name "$env_name"; then
    nyann::warn "slack channel: invalid env var name '$env_name' — skipping"
  else
    deliver_channel slack bash "${channels_dir}/slack.sh" --env "$env_name"
  fi
fi

if [[ "$discord_enabled" == "true" ]]; then
  env_name=$(jq -r '.discord.webhook_url_env // empty' <<<"$delivery")
  if [[ -z "$env_name" ]]; then
    nyann::warn "discord channel enabled but webhook_url_env is unset — skipping"
  elif ! valid_env_name "$env_name"; then
    nyann::warn "discord channel: invalid env var name '$env_name' — skipping"
  else
    deliver_channel discord bash "${channels_dir}/discord.sh" --env "$env_name"
  fi
fi

if [[ "$webhook_enabled" == "true" ]]; then
  env_name=$(jq -r '.webhook.url_env // empty' <<<"$delivery")
  if [[ -z "$env_name" ]]; then
    nyann::warn "webhook channel enabled but url_env is unset — skipping"
  elif ! valid_env_name "$env_name"; then
    nyann::warn "webhook channel: invalid env var name '$env_name' — skipping"
  else
    deliver_channel webhook bash "${channels_dir}/webhook.sh" --env "$env_name"
  fi
fi

if [[ "$email_enabled" == "true" ]]; then
  to=$(jq -r '.email.to // empty'       <<<"$delivery")
  from=$(jq -r '.email.from // empty'   <<<"$delivery")
  smtp_env=$(jq -r '.email.smtp_env // empty' <<<"$delivery")
  if [[ -z "$to" ]]; then
    nyann::warn "email channel enabled but 'to' is unset — skipping"
  elif [[ -n "$smtp_env" ]] && ! valid_env_name "$smtp_env"; then
    nyann::warn "email channel: invalid smtp env var name '$smtp_env' — skipping"
  else
    args=(bash "${channels_dir}/email.sh" --to "$to")
    [[ -n "$from" ]]     && args+=(--from "$from")
    [[ -n "$smtp_env" ]] && args+=(--smtp-env "$smtp_env")
    deliver_channel email "${args[@]}"
  fi
fi

exit 0
