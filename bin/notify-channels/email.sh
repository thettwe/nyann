#!/usr/bin/env bash
# email.sh — deliver a batch of Notification entries by email.
#
# Usage:
#   email.sh --to <addr> --from <addr> [--smtp-env <ENV_VAR_NAME>]
#            < notifications.json
#
# Reads a JSON array of Notification objects on stdin, renders a plain-text
# RFC822 message, and delivers it either through a curl SMTP relay (when
# --smtp-env names an env var that is exported) or local `sendmail`. The
# SMTP relay URL (which may embed credentials) is read from the environment
# at delivery time (indirect expansion of <ENV_VAR_NAME>) — never passed on
# the command line and never stored in preferences.json. `to`/`from` are
# plain addresses, not secrets. No transport available (no curl relay and no
# sendmail) → warn + skip (exit 0), never crash. Invoked by
# bin/notify-deliver.sh; not meant to be called directly by users.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

to=""
from=""
smtp_env=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)         to="${2-}"; shift 2 ;;
    --to=*)       to="${1#--to=}"; shift ;;
    --from)       from="${2-}"; shift 2 ;;
    --from=*)     from="${1#--from=}"; shift ;;
    --smtp-env)   smtp_env="${2-}"; shift 2 ;;
    --smtp-env=*) smtp_env="${1#--smtp-env=}"; shift ;;
    -h|--help)    sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$to" ]] || nyann::die "--to <addr> is required"
[[ -n "$from" ]] || from="nyann@localhost"

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
count="$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)"
[[ "$count" -eq 0 ]] && exit 0

# Render an RFC822 plain-text message. The To header lets `sendmail -t`
# resolve recipients; the body lists one notification per line.
body="$(jq -r '.[] | "[\(.severity)] \(.message)"' <<<"$batch")"
msg_file="$(mktemp -t nyann-email.XXXXXX)"
trap 'rm -f "$msg_file"' EXIT
{
  printf 'To: %s\n' "$to"
  printf 'From: %s\n' "$from"
  printf 'Subject: [nyann] %s notification(s)\n' "$count"
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf '\n'
  printf '%s\n' "$body"
} > "$msg_file"

# Prefer an explicitly configured SMTP relay (a user who named one wants it);
# fall back to local sendmail. The relay URL — which may carry credentials —
# is resolved from the environment by NAME so it never reaches argv.
if [[ -n "$smtp_env" ]] && nyann::has_cmd curl; then
  relay="${!smtp_env-}"
  if [[ -n "$relay" ]]; then
    if ! curl -sS --url "$relay" --mail-from "$from" --mail-rcpt "$to" --upload-file "$msg_file" >/dev/null 2>&1; then
      nyann::warn "email: SMTP relay delivery failed (check \$${smtp_env} and network)"
    fi
    exit 0
  fi
  nyann::warn "email: env var \$${smtp_env} is unset — falling back to sendmail"
fi

if nyann::has_cmd sendmail; then
  if ! sendmail -t -i < "$msg_file"; then
    nyann::warn "email: sendmail delivery failed"
  fi
  exit 0
fi

nyann::warn "email: no transport available (no curl SMTP relay configured and sendmail not installed) — skipping"
exit 0
