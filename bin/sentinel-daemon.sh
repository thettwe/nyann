#!/usr/bin/env bash
# sentinel-daemon.sh — lifecycle manager for the backgrounded CI sentinel.
#
# Usage:
#   sentinel-daemon.sh start  --repo <owner/repo> [--pr <N>] [--interval <s>]
#                             [--max-runtime <s>] [--state-dir <d>]
#                             [--notif-dir <d>] [--supervisor <name>]
#   sentinel-daemon.sh stop    --repo <owner/repo> [--state-dir <d>]
#   sentinel-daemon.sh status  --repo <owner/repo> [--state-dir <d>] [--json]
#   sentinel-daemon.sh restart --repo <owner/repo> [ ...start flags ]
#   sentinel-daemon.sh report  [--state-dir <d>] [--json]
#
#   --aggregate  retarget start|stop|status|restart at the single per-user
#                multi-repo aggregate daemon (sentinel-aggregate.sh, fixed
#                aggregate.sentinel.* file names). --repo is then ignored; the
#                daemon fans out across --watch-list (default
#                ~/.claude/nyann/watch-list.json).
#
# Verbs:
#   start   — launch ci-sentinel.sh --daemon-loop (or, with --aggregate,
#             sentinel-aggregate.sh --daemon-loop) under a platform supervisor
#             (launchd on macOS, systemd USER unit on Linux, nohup fallback),
#             survive terminal close. IDEMPOTENT: a live daemon is left alone
#             (single-instance via the <repo-hash>.sentinel.pid, or
#             aggregate.sentinel.pid for --aggregate).
#   stop    — stop the supervisor unit AND signal the loop, then reap the pid
#             file + daemon liveness block. Clean even if the supervisor is
#             gone.
#   status  — report pid + supervisor + watched repo/PRs (or watched repos for
#             --aggregate); flags a STALE daemon (pid file present, proc dead).
#   restart — stop then start.
#   report  — machine-readable summary of every running daemon, per-repo AND
#             aggregate (consumed by doctor so a running sentinel is never
#             invisible).
#
# Supervisor selection is SOFT: if loading the launchd/systemd unit fails for
# any reason, we fall back to nohup rather than blocking on supervisor quirks.
# Windows is out of scope (Unix-first).
#
# The daemon NEVER blocks a foreground skill: start backgrounds immediately
# (nohup/launchd/systemd all detach), and all writes go to the same
# notification queue read-notifications.sh drains.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

_plugin_root="$(cd "${_script_dir}/.." && pwd)"
_sentinel_bin="${_script_dir}/ci-sentinel.sh"
_aggregate_bin="${_script_dir}/sentinel-aggregate.sh"

# --- Verb dispatch -----------------------------------------------------------
verb="${1-}"
case "$verb" in
  start|stop|status|restart|report) shift ;;
  -h|--help) sed -n '3,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
  "") nyann::die "missing verb — want one of: start|stop|status|restart|report" ;;
  *)  nyann::die "unknown verb: $verb (want start|stop|status|restart|report)" ;;
esac

repo=""
pr_filter=""
interval=120
# 8h orphan backstop — matches ci-sentinel.sh's --daemon-loop default.
max_runtime=28800
state_dir="${HOME}/.claude/nyann/cache"
notif_dir="${HOME}/.claude/nyann/notifications"
log_dir="${HOME}/.claude/nyann/logs"
watch_list="${HOME}/.claude/nyann/watch-list.json"
supervisor_override=""
json_out=false
# --aggregate retargets start|stop|status|restart at the single per-user
# multi-repo aggregate daemon (fixed aggregate.sentinel.* file names) instead
# of a per-repo daemon. --repo is then ignored.
aggregate=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          repo="${2-}"; shift 2 ;;
    --repo=*)        repo="${1#--repo=}"; shift ;;
    --pr)            pr_filter="${2-}"; shift 2 ;;
    --pr=*)          pr_filter="${1#--pr=}"; shift ;;
    --interval)      interval="${2-}"; shift 2 ;;
    --interval=*)    interval="${1#--interval=}"; shift ;;
    --max-runtime)   max_runtime="${2-}"; shift 2 ;;
    --max-runtime=*) max_runtime="${1#--max-runtime=}"; shift ;;
    --state-dir)     state_dir="${2-}"; shift 2 ;;
    --state-dir=*)   state_dir="${1#--state-dir=}"; shift ;;
    --notif-dir)     notif_dir="${2-}"; shift 2 ;;
    --notif-dir=*)   notif_dir="${1#--notif-dir=}"; shift ;;
    --log-dir)       log_dir="${2-}"; shift 2 ;;
    --log-dir=*)     log_dir="${1#--log-dir=}"; shift ;;
    --watch-list)    watch_list="${2-}"; shift 2 ;;
    --watch-list=*)  watch_list="${1#--watch-list=}"; shift ;;
    --supervisor)    supervisor_override="${2-}"; shift 2 ;;
    --supervisor=*)  supervisor_override="${1#--supervisor=}"; shift ;;
    --aggregate)     aggregate=true; shift ;;
    --json)          json_out=true; shift ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

mkdir -p "$state_dir" "$notif_dir" "$log_dir" 2>/dev/null || true

# repo-hash — byte-for-byte identical to ci-sentinel.sh / read-notifications.sh
# so the same per-repo files (pid, daemon block, notification queue) line up.
repo_hash() {
  printf '%s' "$1" | (md5sum 2>/dev/null || md5 -q 2>/dev/null || cksum 2>/dev/null) | tr -dc '0-9a-f' | cut -c1-12
}

# valid_repo_slug <slug> — mirror sentinel-aggregate.sh's: accept only
# <owner>/<repo>, reject a leading `-` (option injection into gh / the plist /
# unit) and any `.`/`..` path component. $repo is substituted UNESCAPED into
# the launchd plist + systemd unit, so it must be validated before render.
valid_repo_slug() {
  local r="${1-}"
  [[ -n "$r" ]] || return 1
  [[ "$r" != -* ]] || return 1
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  case "$r" in
    .|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
  esac
  return 0
}

# pid_is_live <pid> — true iff the pid is alive AND still looks like a
# sentinel (PID-reuse guard, same primitive ci-sentinel.sh --stop uses).
# Matches BOTH the per-repo loop (ci-sentinel) and the multi-repo aggregate
# loop (sentinel-aggregate) — otherwise a live aggregate daemon would be
# falsely classified STALE by status / report.
pid_is_live() {
  local pid="$1" pcmd
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  pcmd=$(ps -p "$pid" -o command= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
  [[ "$pcmd" == *ci-sentinel* || "$pcmd" == *sentinel-aggregate* ]]
}

# select_supervisor — choose launchd (macOS) / systemd (Linux) / nohup.
# Honors --supervisor when given. SOFT: returns "nohup" whenever the
# preferred init system's CLI is absent. Probing is read-only.
select_supervisor() {
  if [[ -n "$supervisor_override" ]]; then
    printf '%s' "$supervisor_override"
    return 0
  fi
  local os
  os=$(uname -s 2>/dev/null || echo unknown)
  case "$os" in
    Darwin)
      if command -v launchctl >/dev/null 2>&1; then printf 'launchd'; return 0; fi ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1; then printf 'systemd'; return 0; fi ;;
  esac
  printf 'nohup'
}

# propagate_delivery_env <supervisor> — make the configured delivery secrets
# reachable by the supervised daemon. The channel scripts resolve their secret
# endpoint by NAME via `printenv`, but launchd agents and systemd --user units
# do NOT inherit interactively-exported shell vars, so under the default
# supervisors every channel would soft-skip forever. We do NOT write the secret
# into the unit file (that re-leaks it to disk). Instead, for each ENABLED
# notifications.delivery.* channel that names an env var, read the NAME from
# preferences.json and, if that var is SET in this (launching) shell, hand its
# value to the supervisor's own environment: `launchctl setenv` (in-memory,
# before bootstrap) for launchd, `systemctl --user import-environment` for
# systemd. nohup already inherits this shell's env. For any enabled channel
# whose var is UNSET here, warn loudly. Best-effort: a missing launchctl /
# systemctl never aborts start.
propagate_delivery_env() {
  local sup="$1"
  local prefs="${NYANN_USER_ROOT:-$HOME/.claude/nyann}/preferences.json"
  [[ -f "$prefs" ]] || return 0
  # Emit "<channel> <env-var-name>" for each enabled channel that names a var.
  local lines
  lines=$(jq -r '
    (.notifications.delivery // {}) as $d
    | [ ($d.slack   | select(.enabled == true) | {c:"slack",   e:.webhook_url_env}),
        ($d.discord | select(.enabled == true) | {c:"discord", e:.webhook_url_env}),
        ($d.webhook | select(.enabled == true) | {c:"webhook", e:.url_env}),
        ($d.email   | select(.enabled == true) | {c:"email",   e:.smtp_env}) ]
    | .[] | select(.e != null and .e != "") | "\(.c) \(.e)"
  ' "$prefs" 2>/dev/null || true)
  [[ -n "$lines" ]] || return 0

  local channel name val
  while read -r channel name; do
    [[ -n "$name" ]] || continue
    val="$(printenv -- "$name" 2>/dev/null || true)"
    if [[ -z "$val" ]]; then
      nyann::warn "delivery channel '$channel' uses \$$name, but it is NOT set in this shell — a launchd/systemd daemon does not inherit your shell exports, so $channel delivery will be SKIPPED. Export $name before 'start' (or run under the nohup supervisor)."
      continue
    fi
    case "$sup" in
      launchd) launchctl setenv "$name" "$val" 2>/dev/null || true ;;
      systemd) systemctl --user import-environment "$name" 2>/dev/null || true ;;
      *) : ;;  # nohup inherits this shell's environment — nothing to propagate
    esac
  done <<<"$lines"
}

# render_template <template> <out> — substitute the ${PLACEHOLDER} tokens in
# the launchd plist / systemd unit. Pure bash string replace (the gen-ci.sh
# convention) — no envsubst dependency.
render_template() {
  local tmpl="$1" out="$2" content pr_args=""
  [[ -f "$tmpl" ]] || { nyann::warn "supervisor template missing: $tmpl"; return 1; }
  content=$(cat "$tmpl")
  # Render the optional --pr filter into the per-repo unit so a supervised
  # daemon honours --pr exactly like the nohup fallback (spawn_nohup). The
  # launchd plist needs it as two ProgramArguments <string> elements; the
  # systemd unit needs it as a single ExecStart token. An unset filter renders
  # empty and leaves no ${PR_ARGS} placeholder behind. Aggregate templates have
  # no ${PR_ARGS} token, so this is a no-op there.
  if [[ -n "$pr_filter" ]]; then
    case "$tmpl" in
      *.plist) pr_args=$'    <string>--pr</string>\n    <string>'"$pr_filter"$'</string>\n' ;;
      *)       pr_args="--pr $pr_filter" ;;
    esac
  fi
  content="${content//\$\{SENTINEL_BIN\}/$_sentinel_bin}"
  content="${content//\$\{AGGREGATE_BIN\}/$_aggregate_bin}"
  content="${content//\$\{REPO\}/$repo}"
  content="${content//\$\{PR_ARGS\}/$pr_args}"
  content="${content//\$\{INTERVAL\}/$interval}"
  content="${content//\$\{MAX_RUNTIME\}/$max_runtime}"
  content="${content//\$\{STATE_DIR\}/$state_dir}"
  content="${content//\$\{NOTIF_DIR\}/$notif_dir}"
  content="${content//\$\{WATCH_LIST\}/$watch_list}"
  content="${content//\$\{LOG_DIR\}/$log_dir}"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  printf '%s\n' "$content" > "$out" 2>/dev/null || {
    nyann::warn "could not write supervisor unit: $out"; return 1;
  }
  return 0
}

# spawn_nohup — the universal fallback. Detaches ci-sentinel.sh --daemon-loop
# so it survives the caller. Never blocks: returns as soon as the child is
# backgrounded.
spawn_nohup() {
  local sup="$1"
  nohup bash "$_sentinel_bin" --daemon-loop \
    --repo "$repo" ${pr_filter:+--pr "$pr_filter"} \
    --interval "$interval" --max-runtime "$max_runtime" \
    --state-dir "$state_dir" --notif-dir "$notif_dir" \
    --supervisor "$sup" \
    >> "$log_dir/sentinel.out.log" 2>> "$log_dir/sentinel.err.log" &
  # Detach from this shell's job table so the parent can exit without
  # the child receiving SIGHUP.
  disown 2>/dev/null || true
}

# load_launchd — generate + bootstrap the plist. SOFT: any failure returns
# non-zero so start() falls back to nohup.
load_launchd() {
  local plist="${HOME}/Library/LaunchAgents/com.nyann.sentinel.plist"
  render_template "${_plugin_root}/templates/launchd/com.nyann.sentinel.plist" "$plist" || return 1
  # `bootstrap` is the modern verb; fall back to legacy `load`. Either failing
  # is non-fatal — we fall back to nohup.
  local uid; uid=$(id -u 2>/dev/null || echo "")
  if [[ -n "$uid" ]] && launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null; then
    return 0
  fi
  if launchctl load "$plist" 2>/dev/null; then
    return 0
  fi
  return 1
}

# unload_launchd — best-effort teardown; never fails the stop path.
unload_launchd() {
  local plist="${HOME}/Library/LaunchAgents/com.nyann.sentinel.plist"
  local uid; uid=$(id -u 2>/dev/null || echo "")
  [[ -n "$uid" ]] && launchctl bootout "gui/${uid}/com.nyann.sentinel" 2>/dev/null || true
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist" 2>/dev/null || true
}

load_systemd() {
  local unit="${HOME}/.config/systemd/user/nyann-sentinel.service"
  render_template "${_plugin_root}/templates/systemd/nyann-sentinel.service" "$unit" || return 1
  systemctl --user daemon-reload 2>/dev/null || true
  if systemctl --user start nyann-sentinel.service 2>/dev/null; then
    return 0
  fi
  return 1
}

unload_systemd() {
  local unit="${HOME}/.config/systemd/user/nyann-sentinel.service"
  systemctl --user stop nyann-sentinel.service 2>/dev/null || true
  rm -f "$unit" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

# --- aggregate supervisor variants (v1.13.0 P10) -----------------------------
# The aggregate daemon fans out across the whole watch-list, so it is launched
# from sentinel-aggregate.sh (not ci-sentinel.sh) and uses distinct unit names
# / labels. Each mirrors its per-repo counterpart above so the SOFT
# supervisor→nohup fallback behaves identically.

# spawn_nohup_aggregate — universal fallback for the aggregate daemon.
spawn_nohup_aggregate() {
  local sup="$1"
  nohup bash "$_aggregate_bin" --daemon-loop \
    --interval "$interval" --max-runtime "$max_runtime" \
    --state-dir "$state_dir" --notif-dir "$notif_dir" \
    --watch-list "$watch_list" \
    --supervisor "$sup" \
    >> "$log_dir/sentinel-aggregate.out.log" 2>> "$log_dir/sentinel-aggregate.err.log" &
  disown 2>/dev/null || true
}

load_launchd_aggregate() {
  local plist="${HOME}/Library/LaunchAgents/com.nyann.sentinel-aggregate.plist"
  render_template "${_plugin_root}/templates/launchd/com.nyann.sentinel-aggregate.plist" "$plist" || return 1
  local uid; uid=$(id -u 2>/dev/null || echo "")
  if [[ -n "$uid" ]] && launchctl bootstrap "gui/${uid}" "$plist" 2>/dev/null; then
    return 0
  fi
  if launchctl load "$plist" 2>/dev/null; then
    return 0
  fi
  return 1
}

unload_launchd_aggregate() {
  local plist="${HOME}/Library/LaunchAgents/com.nyann.sentinel-aggregate.plist"
  local uid; uid=$(id -u 2>/dev/null || echo "")
  [[ -n "$uid" ]] && launchctl bootout "gui/${uid}/com.nyann.sentinel-aggregate" 2>/dev/null || true
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist" 2>/dev/null || true
}

load_systemd_aggregate() {
  local unit="${HOME}/.config/systemd/user/nyann-sentinel-aggregate.service"
  render_template "${_plugin_root}/templates/systemd/nyann-sentinel-aggregate.service" "$unit" || return 1
  systemctl --user daemon-reload 2>/dev/null || true
  if systemctl --user start nyann-sentinel-aggregate.service 2>/dev/null; then
    return 0
  fi
  return 1
}

unload_systemd_aggregate() {
  local unit="${HOME}/.config/systemd/user/nyann-sentinel-aggregate.service"
  systemctl --user stop nyann-sentinel-aggregate.service 2>/dev/null || true
  rm -f "$unit" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

# --- start (aggregate) -------------------------------------------------------
# Launch the single per-user multi-repo aggregate daemon. Idempotent: a live
# aggregate daemon is left alone; a stale pid file is reclaimed. Mirrors the
# per-repo do_start, including the SOFT supervisor→nohup fallback.
do_start_aggregate() {
  local pid_file="$state_dir/aggregate.sentinel.pid"

  if [[ -f "$pid_file" ]]; then
    local existing; existing=$(cat "$pid_file" 2>/dev/null || true)
    if pid_is_live "$existing"; then
      echo "[nyann sentinel] aggregate daemon already running (pid $existing)"
      return 0
    fi
    rm -f "$pid_file" 2>/dev/null || true
  fi

  local sup; sup=$(select_supervisor)
  # Make the configured delivery secrets reachable by the supervised daemon
  # (launchd/systemd don't inherit shell exports) and warn for any enabled
  # channel whose secret env var isn't exported in this shell.
  propagate_delivery_env "$sup"
  local launched=""
  case "$sup" in
    launchd)
      if load_launchd_aggregate; then launched="launchd"; else
        nyann::warn "launchd load failed — falling back to nohup (best-effort)"
        spawn_nohup_aggregate "nohup"; launched="nohup"
      fi ;;
    systemd)
      if load_systemd_aggregate; then launched="systemd"; else
        nyann::warn "systemd load failed — falling back to nohup (best-effort)"
        spawn_nohup_aggregate "nohup"; launched="nohup"
      fi ;;
    *)
      spawn_nohup_aggregate "nohup"; launched="nohup" ;;
  esac

  echo "[nyann sentinel] aggregate daemon started (supervisor: $launched)"
  return 0
}

# --- start -------------------------------------------------------------------
do_start() {
  # Validate the numeric tunables before launching EITHER daemon variant: they
  # are substituted into the plist/unit and passed to the loop, so a typo must
  # fail fast rather than spin a no-sleep loop (mirrors ci-sentinel.sh).
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
    nyann::die "start: --interval must be a positive integer of seconds (got: $interval)"
  fi
  if ! [[ "$max_runtime" =~ ^[0-9]+$ ]] || (( max_runtime < 1 )); then
    nyann::die "start: --max-runtime must be a positive integer of seconds (got: $max_runtime)"
  fi
  if $aggregate; then do_start_aggregate; return $?; fi
  [[ -n "$repo" ]] || nyann::die "start: --repo <owner/repo> is required"
  # $repo is rendered UNESCAPED into the plist/unit — reject a slug that could
  # inject options or path components before it's hashed/substituted.
  valid_repo_slug "$repo" || nyann::die "start: invalid repo (expected <owner>/<repo>): $repo"
  # --pr is substituted UNESCAPED into the plist/unit and forwarded to the loop
  # — require a positive integer (mirrors ci-sentinel.sh) so a typo or an
  # injected token can't reach the rendered unit.
  if [[ -n "$pr_filter" ]] && ! [[ "$pr_filter" =~ ^[0-9]+$ ]]; then
    nyann::die "start: --pr must be a positive integer (got: $pr_filter)"
  fi
  local hash; hash=$(repo_hash "$repo")
  local pid_file="$state_dir/${hash}.sentinel.pid"

  # Idempotent: a live daemon for this repo means there's nothing to do.
  if [[ -f "$pid_file" ]]; then
    local existing; existing=$(cat "$pid_file" 2>/dev/null || true)
    if pid_is_live "$existing"; then
      echo "[nyann sentinel] daemon already running for $repo (pid $existing)"
      return 0
    fi
    # Stale pid file — reclaim before starting.
    rm -f "$pid_file" 2>/dev/null || true
  fi

  local sup; sup=$(select_supervisor)
  # Make the configured delivery secrets reachable by the supervised daemon
  # (launchd/systemd don't inherit shell exports) and warn for any enabled
  # channel whose secret env var isn't exported in this shell.
  propagate_delivery_env "$sup"
  local launched=""
  case "$sup" in
    launchd)
      if load_launchd; then launched="launchd"; else
        nyann::warn "launchd load failed — falling back to nohup (best-effort)"
        spawn_nohup "nohup"; launched="nohup"
      fi ;;
    systemd)
      if load_systemd; then launched="systemd"; else
        nyann::warn "systemd load failed — falling back to nohup (best-effort)"
        spawn_nohup "nohup"; launched="nohup"
      fi ;;
    *)
      spawn_nohup "nohup"; launched="nohup" ;;
  esac

  echo "[nyann sentinel] daemon started for $repo (supervisor: $launched)"
  return 0
}

# --- stop (aggregate) --------------------------------------------------------
# Tear down the aggregate supervisor unit (best-effort), signal the loop via
# sentinel-aggregate.sh --stop, then reap the fixed-name pid + liveness block.
do_stop_aggregate() {
  local pid_file="$state_dir/aggregate.sentinel.pid"
  local daemon_file="$state_dir/aggregate.sentinel.daemon.json"

  local recorded_sup=""
  [[ -f "$daemon_file" ]] && recorded_sup=$(jq -r '.daemon.supervisor // ""' "$daemon_file" 2>/dev/null || echo "")
  case "$recorded_sup" in
    launchd) unload_launchd_aggregate ;;
    systemd) unload_systemd_aggregate ;;
    *) # Unknown — try both teardowns; they're individually safe no-ops.
       command -v launchctl >/dev/null 2>&1 && unload_launchd_aggregate
       command -v systemctl >/dev/null 2>&1 && unload_systemd_aggregate ;;
  esac

  bash "$_aggregate_bin" --stop --state-dir "$state_dir" --notif-dir "$notif_dir" >/dev/null 2>&1 || true
  rm -f "$pid_file" "$daemon_file" 2>/dev/null || true
  echo "[nyann sentinel] aggregate daemon stopped"
  return 0
}

# --- stop --------------------------------------------------------------------
do_stop() {
  if $aggregate; then do_stop_aggregate; return $?; fi
  [[ -n "$repo" ]] || nyann::die "stop: --repo <owner/repo> is required"
  local hash; hash=$(repo_hash "$repo")
  local pid_file="$state_dir/${hash}.sentinel.pid"
  local daemon_file="$state_dir/${hash}.sentinel.daemon.json"

  # Tear down whichever supervisor we may have loaded. Reads the recorded
  # supervisor from the daemon block when present; otherwise tries both
  # (each is a no-op when the unit isn't installed).
  local recorded_sup=""
  [[ -f "$daemon_file" ]] && recorded_sup=$(jq -r '.daemon.supervisor // ""' "$daemon_file" 2>/dev/null || echo "")
  case "$recorded_sup" in
    launchd) unload_launchd ;;
    systemd) unload_systemd ;;
    *) # Unknown — try both teardowns; they're individually safe no-ops.
       command -v launchctl >/dev/null 2>&1 && unload_launchd
       command -v systemctl >/dev/null 2>&1 && unload_systemd ;;
  esac

  # Signal the loop directly via ci-sentinel.sh --stop (handles the
  # PID-reuse guard + pid-file reap). Then make sure the daemon block is gone.
  bash "$_sentinel_bin" --repo "$repo" --stop --state-dir "$state_dir" --notif-dir "$notif_dir" >/dev/null 2>&1 || true
  rm -f "$pid_file" "$daemon_file" 2>/dev/null || true
  echo "[nyann sentinel] daemon stopped for $repo"
  return 0
}

# --- status (aggregate) ------------------------------------------------------
# Report the single aggregate daemon (running / stale / none). Instead of
# per-PR state files, list the repos the watch-list fans out across.
do_status_aggregate() {
  local pid_file="$state_dir/aggregate.sentinel.pid"
  local daemon_file="$state_dir/aggregate.sentinel.daemon.json"

  local pid="" sup="" started="" running=false stale=false
  [[ -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -f "$daemon_file" ]]; then
    sup=$(jq -r '.daemon.supervisor // ""' "$daemon_file" 2>/dev/null || echo "")
    started=$(jq -r '.daemon.started_at // ""' "$daemon_file" 2>/dev/null || echo "")
  fi

  if [[ -n "$pid" ]]; then
    if pid_is_live "$pid"; then running=true; else stale=true; fi
  fi

  # Watched repos — read the watch-list the aggregator fans out across.
  local watched_repos=()
  local r
  if [[ -f "$watch_list" ]]; then
    while IFS= read -r r; do
      [[ -n "$r" ]] && watched_repos+=("$r")
    done < <(jq -r '.[]?.repo // empty' "$watch_list" 2>/dev/null || true)
  fi

  if $json_out; then
    local repos_json="[]"
    if (( ${#watched_repos[@]} > 0 )); then
      repos_json=$(printf '%s\n' "${watched_repos[@]}" | jq -R . | jq -s '.')
    fi
    jq -n \
      --arg pid "${pid:-}" \
      --arg sup "${sup:-}" \
      --arg started "${started:-}" \
      --argjson running "$running" \
      --argjson stale "$stale" \
      --argjson repos "$repos_json" \
      '{aggregate:true, running:$running, stale:$stale,
        pid:(if $pid=="" then null else ($pid|tonumber? // null) end),
        supervisor:(if $sup=="" then null else $sup end),
        started_at:(if $started=="" then null else $started end),
        watched_repos:$repos}'
    return 0
  fi

  if $running; then
    echo "[nyann sentinel] aggregate daemon running — pid ${pid}, supervisor ${sup:-unknown}, started ${started:-?}"
  elif $stale; then
    echo "[nyann sentinel] STALE aggregate daemon — pid file points at ${pid} but no live sentinel; run /nyann:watch --stop to reap"
  else
    echo "[nyann sentinel] no aggregate daemon running"
  fi
  if (( ${#watched_repos[@]} > 0 )); then
    echo "  watched repos: ${watched_repos[*]}"
  fi
  return 0
}

# --- status ------------------------------------------------------------------
do_status() {
  if $aggregate; then do_status_aggregate; return $?; fi
  [[ -n "$repo" ]] || nyann::die "status: --repo <owner/repo> is required"
  local hash; hash=$(repo_hash "$repo")
  local pid_file="$state_dir/${hash}.sentinel.pid"
  local daemon_file="$state_dir/${hash}.sentinel.daemon.json"

  local pid="" sup="" started="" running=false stale=false
  [[ -f "$pid_file" ]] && pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -f "$daemon_file" ]]; then
    sup=$(jq -r '.daemon.supervisor // ""' "$daemon_file" 2>/dev/null || echo "")
    started=$(jq -r '.daemon.started_at // ""' "$daemon_file" 2>/dev/null || echo "")
  fi

  if [[ -n "$pid" ]]; then
    if pid_is_live "$pid"; then
      running=true
    else
      # Pid file (or daemon block) present but the process is gone — a STALE
      # daemon. Surface it so it's never invisible; reaping is left to `stop`.
      stale=true
    fi
  fi

  # Watched PRs — read the per-PR state files for this repo.
  local watched_prs=()
  local f
  for f in "$state_dir/${hash}.pr"*.sentinel.json; do
    [[ -e "$f" ]] || continue
    local n; n=$(jq -r '.pr_number // empty' "$f" 2>/dev/null || true)
    [[ -n "$n" ]] && watched_prs+=("$n")
  done

  if $json_out; then
    local prs_json="[]"
    if (( ${#watched_prs[@]} > 0 )); then
      prs_json=$(printf '%s\n' "${watched_prs[@]}" | jq -R 'tonumber? // empty' | jq -s '.')
    fi
    jq -n \
      --arg repo "$repo" \
      --arg pid "${pid:-}" \
      --arg sup "${sup:-}" \
      --arg started "${started:-}" \
      --argjson running "$running" \
      --argjson stale "$stale" \
      --argjson prs "$prs_json" \
      '{repo:$repo, running:$running, stale:$stale,
        pid:(if $pid=="" then null else ($pid|tonumber? // null) end),
        supervisor:(if $sup=="" then null else $sup end),
        started_at:(if $started=="" then null else $started end),
        watched_prs:$prs}'
    return 0
  fi

  if $running; then
    echo "[nyann sentinel] running for $repo — pid ${pid}, supervisor ${sup:-unknown}, started ${started:-?}"
  elif $stale; then
    echo "[nyann sentinel] STALE daemon for $repo — pid file points at ${pid} but no live sentinel; run /nyann:watch --stop to reap"
  else
    echo "[nyann sentinel] no daemon running for $repo"
  fi
  if (( ${#watched_prs[@]} > 0 )); then
    echo "  watched PRs: ${watched_prs[*]}"
  fi
  return 0
}

# --- restart -----------------------------------------------------------------
do_restart() {
  # --aggregate restarts the per-user aggregate daemon; --repo isn't required
  # then (do_stop/do_start dispatch on $aggregate themselves).
  if ! $aggregate; then
    [[ -n "$repo" ]] || nyann::die "restart: --repo <owner/repo> is required"
  fi
  do_stop
  do_start
  return 0
}

# --- report ------------------------------------------------------------------
# Emit a compact JSON array of every running/stale daemon found under
# state_dir. Doctor folds this in so a running sentinel is never invisible.
do_report() {
  local out="[]" f hash pid sup started running stale
  for f in "$state_dir"/*.sentinel.daemon.json; do
    [[ -e "$f" ]] || continue
    pid=$(jq -r '.daemon.pid // empty' "$f" 2>/dev/null || true)
    sup=$(jq -r '.daemon.supervisor // ""' "$f" 2>/dev/null || echo "")
    started=$(jq -r '.daemon.started_at // ""' "$f" 2>/dev/null || echo "")
    local drepo; drepo=$(jq -r '.repo // ""' "$f" 2>/dev/null || echo "")
    running=false; stale=false
    if pid_is_live "$pid"; then running=true; else stale=true; fi
    out=$(jq -n \
      --argjson acc "$out" \
      --arg repo "$drepo" \
      --arg pid "${pid:-}" \
      --arg sup "$sup" \
      --arg started "$started" \
      --argjson running "$running" \
      --argjson stale "$stale" \
      '$acc + [{repo:$repo,
                pid:(if $pid=="" then null else ($pid|tonumber? // null) end),
                supervisor:(if $sup=="" then null else $sup end),
                started_at:(if $started=="" then null else $started end),
                running:$running, stale:$stale}]')
  done
  printf '%s\n' "$out"
  return 0
}

case "$verb" in
  start)   do_start ;;
  stop)    do_stop ;;
  status)  do_status ;;
  restart) do_restart ;;
  report)  do_report ;;
esac
