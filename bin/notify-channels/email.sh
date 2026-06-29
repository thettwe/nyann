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
# SMTP relay URL (which may embed credentials) is read from the environment at
# delivery time via `printenv` (NEVER bash indirect expansion `${!name}`,
# which arithmetic-evaluates array subscripts and would run an attacker
# substring like `x[$(cmd)]` — RCE). The relay URL is then handed to curl via
# a 0600 `-K` config file so the credentials NEVER reach argv (`ps`). `to`/
# `from` are plain addresses, not secrets, but CR/LF is stripped from them so
# a newline in prefs can't inject extra RFC822 headers.
#
# EXIT CONTRACT (shared with notify-deliver.sh): exit 0 ONLY on a confirmed
# delivery. A soft-skip (no transport, unset relay env, invalid env name) or a
# failed send returns NON-ZERO (75 for soft-skip, or the transport's own
# status) so the orchestrator leaves the notification UN-marked and retries
# it. Invoked by bin/notify-deliver.sh; not for direct user use.

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

# Strip CR/LF from the addresses BEFORE they go into RFC822 headers: a newline
# in `email.to`/`email.from` would otherwise inject extra headers (or a body)
# into the message — classic header injection. settings.sh also rejects CR/LF
# on the write path; this is the defense-in-depth read-site strip.
to=${to//[$'\r\n']/}
from=${from//[$'\r\n']/}

batch="$(cat)"
[[ -n "$batch" ]] || exit 0
count="$(jq 'length' <<<"$batch" 2>/dev/null || echo 0)"
[[ "$count" -eq 0 ]] && exit 0

# Render an RFC822 plain-text message. The To header lets `sendmail -t`
# resolve recipients; the body lists one notification per line, each tagged
# with its repo (context.repo, set by notify-deliver) for aggregate clarity.
body="$(jq -r '.[] | "\(if .context.repo then "[\(.context.repo)] " else "" end)[\(.severity)] \(.message)"' <<<"$batch")"
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
# is resolved from the environment by NAME (printenv, never `${!name}`) and
# handed to curl through a 0600 `-K` config file so it never reaches argv.
if [[ -n "$smtp_env" ]] && nyann::has_cmd curl; then
  if [[ ! "$smtp_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    nyann::warn "email: invalid smtp env var name '$smtp_env' — skipping"
    exit 75
  fi
  relay="$(printenv -- "$smtp_env" 2>/dev/null || true)"
  if [[ -n "$relay" ]]; then
    # Write the (possibly credential-bearing) relay URL to a private config
    # file so it never appears in argv / `ps`. curl reads `url = "..."` from
    # the -K file the same as --url.
    curl_conf="$(mktemp -t nyann-smtp.XXXXXX)"
    trap 'rm -f "$msg_file" "$curl_conf"' EXIT
    ( umask 077; printf 'url = "%s"\n' "$relay" > "$curl_conf" )
    rc=0
    curl --fail -sS --connect-timeout 5 --max-time 15 -K "$curl_conf" \
      --mail-from "$from" --mail-rcpt "$to" --upload-file "$msg_file" >/dev/null 2>&1 || rc=$?
    rm -f "$curl_conf"
    trap 'rm -f "$msg_file"' EXIT
    if (( rc != 0 )); then
      nyann::warn "email: SMTP relay delivery failed (check \$${smtp_env} and network)"
    fi
    exit "$rc"
  fi
  nyann::warn "email: env var \$${smtp_env} is unset — falling back to sendmail"
fi

if nyann::has_cmd sendmail; then
  # Wrap sendmail in `timeout` when available so a hung MTA can't wedge the
  # poll loop; fall back to a plain invocation where `timeout` is absent
  # (e.g. stock macOS). Return the transport's status.
  rc=0
  if nyann::has_cmd timeout; then
    timeout 30 sendmail -t -i < "$msg_file" || rc=$?
  else
    sendmail -t -i < "$msg_file" || rc=$?
  fi
  if (( rc != 0 )); then
    nyann::warn "email: sendmail delivery failed"
  fi
  exit "$rc"
fi

nyann::warn "email: no transport available (no curl SMTP relay configured and sendmail not installed) — skipping"
exit 75
