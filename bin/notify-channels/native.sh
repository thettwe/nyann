#!/usr/bin/env bash
# native.sh — deliver a batch of Notification entries as ONE native OS
# notification (macOS osascript `display notification`, Linux notify-send).
#
# Usage:
#   native.sh   < notifications.json
#
# The batch collapses to a single toast — "[critical] CI failed on o/r" or
# "[critical] first message (+2 more)" — because a burst of N toasts is
# noise, not signal. Tool pick is by availability (osascript first, then
# notify-send), which is naturally portable AND stubbable in tests.
#
# INJECTION HARDENING is the whole job here: notification text is attacker-
# influenceable (PR titles, branch names). Control characters are stripped
# and the text is length-capped in jq; for AppleScript, backslashes and
# double quotes are escaped BEFORE interpolation into the `display
# notification` statement (AppleScript strings interpret only \" and \\ —
# there is no $()/backtick expansion — so that closes the string-breakout);
# for notify-send the text rides argv as a single quoted argument with a
# leading-dash guard so it can never be parsed as an option.
#
# EXIT CONTRACT (shared with notify-deliver.sh): exit 0 ONLY on a confirmed
# display. Soft-skips (no tool, headless session) return 75; a failed tool
# invocation returns its status — either way the orchestrator leaves the
# batch UN-marked for this channel and retries it next poll.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
if [[ "$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)" -eq 0 ]]; then
  exit 0
fi

# One toast for the whole batch. Control chars stripped, capped at 180 chars.
text=$(jq -r '
  def clean: tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode;
  ( .[0] |
    "[" + (.severity // "info" | clean) + "] "
    + (if .context.repo then "[" + (.context.repo | clean) + "] " else "" end)
    + (.message // "" | clean) ) as $first |
  (if length > 1 then $first + " (+\(length - 1) more)" else $first end)
  | .[0:180]' <<<"$batch" 2>/dev/null || true)
if [[ -z "$text" ]]; then
  nyann::warn "native: could not compose notification text — skipping"
  exit 75
fi
# Leading-dash guard: the composed text always starts with "[", but a
# defensive space keeps a hand-crafted batch from ever reaching argv as an
# option.
[[ "$text" == -* ]] && text=" $text"

if nyann::has_cmd osascript; then
  # Escape for an AppleScript double-quoted string: backslash FIRST, then
  # the quote (order matters — the other way doubles our own escapes).
  esc="$text"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  script=$(printf 'display notification "%s" with title "nyann"' "$esc")
  rc=0
  osascript -e "$script" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    nyann::warn "native: osascript failed (headless session?)"
  fi
  exit "$rc"
fi

if nyann::has_cmd notify-send; then
  # No GUI session → the send would silently vanish or error; soft-skip so
  # the batch is retried when a session exists.
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    nyann::warn "native: no GUI session (DISPLAY/WAYLAND_DISPLAY/DBUS unset) — skipping"
    exit 75
  fi
  rc=0
  notify-send "nyann" "$text" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    nyann::warn "native: notify-send failed"
  fi
  exit "$rc"
fi

nyann::warn "native: neither osascript nor notify-send is available — skipping"
exit 75
