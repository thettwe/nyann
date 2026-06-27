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
# DEDUP (correct-by-construction): a notification's content hash is recorded
# in a per-repo marker ONLY once at least one channel CONFIRMS delivery (exit
# 0). A soft-skip (unset env / missing curl) or a failed POST leaves the id
# UN-marked so the next poll retries it — the queue reader feeds us via
# `--peek` (non-draining), so a prematurely-marked id would otherwise be
# suppressed FOREVER. The marker is rewritten each run, under its lock, to
# `(ids delivered this run) ∪ (existing-marker ids ∩ current-batch ids)`:
# bounded to the live queue (no fixed cap to re-deliver past), never drops a
# still-queued id, never re-sends a delivered one. The lock spans the dedup
# scan AND the record so the check/record is atomic (no TOCTOU).
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

# --- Dedup against the per-repo delivered-marker -----------------------------
repo_hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-16)
marker="${cache_dir}/${repo_hash}.delivered"

hash_id() {
  printf '%s' "$1" | (md5sum 2>/dev/null || md5 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-16
}

# valid_env_name <name> — strict POSIX identifier. A delivery *_env value that
# fails this must never reach a channel's resolver (defense in depth against
# the `${!name}` arithmetic-subscript RCE, even though the channel re-checks).
valid_env_name() { [[ "${1-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# Hold the marker lock across BOTH the dedup scan and the record so the
# check-then-record is atomic (fixes the TOCTOU). The EXIT trap guarantees the
# lock is released even if a step trips errexit mid-way.
mkdir -p "$cache_dir" 2>/dev/null || true
lock_dir="${marker}.lock"
nyann::lock "$lock_dir"
trap 'nyann::unlock "$lock_dir"' EXIT

# Compute the id of every entry in the current batch (same hashing as before),
# and split into NEW (not yet in the marker) vs already-recorded. batch_ids is
# the full live-queue id set — used below to bound the rewritten marker.
batch_ids=()
new_elems=()
new_ids=()
for (( i = 0; i < total; i++ )); do
  elem=$(jq -c ".[$i]" <<<"$batch")
  id=$(hash_id "$elem")
  batch_ids+=("$id")
  if [[ -f "$marker" ]] && grep -qxF "$id" "$marker" 2>/dev/null; then
    continue
  fi
  new_elems+=("$elem")
  new_ids+=("$id")
done

# rewrite_marker — atomically replace the marker with
#   (delivered_ids this run) ∪ (existing-marker ids ∩ batch_ids)
# This bounds the marker to live-queue ids (no fixed cap to re-deliver past),
# never drops a still-queued id, and never re-delivers a recorded one.
delivered_ids=()
rewrite_marker() {
  local tmp_ids="${marker}.batchids.$$" tmp_keep="${marker}.keep.$$" tmp_out="${marker}.rewrite.$$"
  : > "$tmp_keep" 2>/dev/null || true
  printf '%s\n' "${batch_ids[@]}" > "$tmp_ids" 2>/dev/null || true
  # existing-marker ids still present in the current batch
  [[ -f "$marker" ]] && grep -xF -f "$tmp_ids" "$marker" >> "$tmp_keep" 2>/dev/null || true
  # ids confirmed delivered this run
  (( ${#delivered_ids[@]} > 0 )) && printf '%s\n' "${delivered_ids[@]}" >> "$tmp_keep" 2>/dev/null || true
  sort -u "$tmp_keep" > "$tmp_out" 2>/dev/null || true
  mv "$tmp_out" "$marker" 2>/dev/null || true
  rm -f "$tmp_ids" "$tmp_keep" 2>/dev/null || true
}

# Everything already delivered → no delivery, but still rewrite the marker to
# bound it to the live queue (drops ids no longer queued).
if (( ${#new_elems[@]} == 0 )); then
  rewrite_marker
  nyann::unlock "$lock_dir"
  trap - EXIT
  exit 0
fi

# Tag every new entry with context.repo (mirrors read-notifications.sh --all)
# so a multi-repo aggregate delivery says which repo each entry is from. The
# dedup id was already computed on the UNTAGGED element, so tagging here can't
# perturb dedup across runs.
new_batch=$(printf '%s\n' "${new_elems[@]}" | jq -s --arg r "$repo" 'map(.context = ((.context // {}) + {repo: $r}))')

# --- Fan out to each enabled channel -----------------------------------------
# Each channel reads the batch on stdin and resolves its secret endpoint from
# the named env var itself. A channel enabled but missing/invalid its env-var
# NAME (or email `to`) is skipped with a warning — never fatal. We track
# whether ANY channel CONFIRMED delivery (exit 0); only then is the batch
# marked delivered, so a soft-skip/failure leaves the ids queued for retry.
slack_enabled=$(jq -r '.slack.enabled // false'   <<<"$delivery")
discord_enabled=$(jq -r '.discord.enabled // false' <<<"$delivery")
webhook_enabled=$(jq -r '.webhook.enabled // false' <<<"$delivery")
email_enabled=$(jq -r '.email.enabled // false'   <<<"$delivery")

any_delivered=false

if [[ "$slack_enabled" == "true" ]]; then
  env_name=$(jq -r '.slack.webhook_url_env // empty' <<<"$delivery")
  if [[ -z "$env_name" ]]; then
    nyann::warn "slack channel enabled but webhook_url_env is unset — skipping"
  elif ! valid_env_name "$env_name"; then
    nyann::warn "slack channel: invalid env var name '$env_name' — skipping"
  elif printf '%s' "$new_batch" | bash "${channels_dir}/slack.sh" --env "$env_name"; then
    any_delivered=true
  fi
fi

if [[ "$discord_enabled" == "true" ]]; then
  env_name=$(jq -r '.discord.webhook_url_env // empty' <<<"$delivery")
  if [[ -z "$env_name" ]]; then
    nyann::warn "discord channel enabled but webhook_url_env is unset — skipping"
  elif ! valid_env_name "$env_name"; then
    nyann::warn "discord channel: invalid env var name '$env_name' — skipping"
  elif printf '%s' "$new_batch" | bash "${channels_dir}/discord.sh" --env "$env_name"; then
    any_delivered=true
  fi
fi

if [[ "$webhook_enabled" == "true" ]]; then
  env_name=$(jq -r '.webhook.url_env // empty' <<<"$delivery")
  if [[ -z "$env_name" ]]; then
    nyann::warn "webhook channel enabled but url_env is unset — skipping"
  elif ! valid_env_name "$env_name"; then
    nyann::warn "webhook channel: invalid env var name '$env_name' — skipping"
  elif printf '%s' "$new_batch" | bash "${channels_dir}/webhook.sh" --env "$env_name"; then
    any_delivered=true
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
    args=(--to "$to")
    [[ -n "$from" ]]     && args+=(--from "$from")
    [[ -n "$smtp_env" ]] && args+=(--smtp-env "$smtp_env")
    if printf '%s' "$new_batch" | bash "${channels_dir}/email.sh" "${args[@]}"; then
      any_delivered=true
    fi
  fi
fi

# --- Record only what was actually delivered ---------------------------------
# Mark the batch delivered ONLY if at least one channel confirmed it. Then
# rewrite the marker (still under the lock acquired above) so the record is
# atomic with the dedup scan and bounded to the live queue.
if $any_delivered; then
  delivered_ids=("${new_ids[@]}")
fi
rewrite_marker
nyann::unlock "$lock_dir"
trap - EXIT

exit 0
