#!/usr/bin/env bash
# _lib.sh — shared helpers for nyann bin scripts.
#
# Sourced at the top of every bin script. Centralizes logging,
# prerequisite checks, and safe shell settings.

# Strict mode: abort on unset vars and pipe failures. Callers that
# intentionally allow failure use `|| true` explicitly.
set -o errexit
set -o nounset
set -o pipefail

# --- Logging ------------------------------------------------------------------
# Writes to stderr so script stdout stays clean for JSON payloads.

nyann::log() {
  printf '[nyann] %s\n' "$*" >&2
}

nyann::warn() {
  printf '[nyann] warn: %s\n' "$*" >&2
}

nyann::die() {
  printf '[nyann] error: %s\n' "$*" >&2
  exit 1
}

# --- Prerequisite checks ------------------------------------------------------

nyann::require_cmd() {
  # $1 = command, $2 = optional install hint surfaced in the error.
  local cmd="$1"
  local hint="${2-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      nyann::die "required command not found: $cmd. Install: $hint"
    else
      nyann::die "required command not found: $cmd"
    fi
  fi
}

nyann::has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# nyann::has_python_yaml — soft check used by scripts that can degrade
# gracefully when python3 or PyYAML is missing. Returns 0 if usable,
# non-zero otherwise. Logs nothing — caller decides how to report.
nyann::has_python_yaml() {
  command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1
}

# --- Path safety --------------------------------------------------------------
# Preventing path-traversal escapes via user-controlled JSON fields
# (ActionPlan paths, DocumentationPlan targets, --changelog, team-source
# names, etc.) is a shared concern across callers. Keep the resolution
# logic in one place so new subsystems can't silently skip it.

# nyann::path_under_target <target> <candidate>
# Canonicalises <candidate> (collapsing `..`, following symlinks) and
# verifies it resolves to <target> or a descendant. On success, prints
# the canonical candidate to stdout and returns 0. On failure (escape,
# missing args) prints nothing and returns 1.
#
# Works for non-existent candidates: resolves the nearest existing
# ancestor via cd+pwd -P (follows symlinks), then lexically normalizes
# any remaining non-existent suffix (collapsing .. components). Pure
# bash — no python subprocess.
nyann::path_under_target() {
  local target="${1-}" cand="${2-}"
  [[ -n "$target" && -n "$cand" ]] || return 1

  local resolved_target
  resolved_target=$(cd "$target" 2>/dev/null && pwd -P) || return 1

  [[ "$cand" == /* ]] || cand="$PWD/$cand"

  # Walk up to the nearest existing ancestor.
  local existing="$cand" tail=""
  while [[ ! -e "$existing" ]]; do
    [[ "$existing" == "/" ]] && return 1
    tail="/$(basename "$existing")$tail"
    existing=$(dirname "$existing")
  done

  local resolved_base
  if [[ -d "$existing" ]]; then
    resolved_base=$(cd "$existing" && pwd -P) || return 1
  else
    resolved_base="$(cd "$(dirname "$existing")" && pwd -P)/$(basename "$existing")" || return 1
  fi

  # Lexically normalize .. in the non-existent tail.
  local result="$resolved_base"
  local oIFS="$IFS" seg
  IFS='/'
  for seg in $tail; do
    case "$seg" in
      ''|.) ;;
      ..)  result=$(dirname "$result") ;;
      *)   result="$result/$seg" ;;
    esac
  done
  IFS="$oIFS"

  if [[ "$result" == "$resolved_target" || "$result" == "$resolved_target"/* ]]; then
    printf '%s\n' "$result"
    return 0
  fi
  return 1
}

# nyann::assert_path_under_target <target> <candidate> <context>
# Resolves <candidate> against <target> via nyann::path_under_target. On
# success, prints the canonical path to stdout. On failure, dies with a
# message that includes <context> (e.g. "plan write path", "--changelog")
# so the operator can trace which caller rejected the input.
nyann::assert_path_under_target() {
  local target="$1" cand="$2" context="$3"
  local resolved
  if resolved=$(nyann::path_under_target "$target" "$cand"); then
    printf '%s\n' "$resolved"
    return 0
  fi
  nyann::die "$context escapes target directory: $cand"
}

# nyann::valid_profile_name <name>
# Returns 0 if <name> matches ^[a-z0-9][a-z0-9-]*$ (the canonical
# profile / team-source identifier pattern), 1 otherwise. Kept as a
# helper so every read path (not just the write path) can re-validate.
nyann::valid_profile_name() {
  [[ "${1-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

# nyann::valid_git_ref <ref>
# Returns 0 if <ref> matches ^[A-Za-z0-9_./:-]+$ AND doesn't start with
# `-` (which git would parse as an option). Not a full git-ref-safety
# check — git itself still refuses `..` components etc. — but enough
# to block the `--upload-pack=cmd`-style option-injection attack.
nyann::valid_git_ref() {
  local r="${1-}"
  [[ -n "$r" ]] || return 1
  [[ "$r" != -* ]] || return 1
  [[ "$r" =~ ^[A-Za-z0-9_./:-]+$ ]]
}

# nyann::valid_git_url <url>
# Returns 0 if <url> uses an allowlisted scheme. The key thing to block
# is git's `ext::` transport (arbitrary command execution) and anything
# starting with `-` (git option injection). file:// is allowed because
# local mirrors / test fixtures rely on it and its worst-case impact is
# bounded (git clone from a local path — same level of access the
# caller already had). `http://` is rejected: a passive-MITM attacker
# could swap profile content (which then drives `git clone` of further
# repos and templates `ci.yml` / hooks). Use `https://` instead.
nyann::valid_git_url() {
  local u="${1-}"
  [[ -n "$u" ]] || return 1
  [[ "$u" != -* ]] || return 1
  case "$u" in
    https://*|ssh://*|git://*|git@*|file://*) return 0 ;;
    *) return 1 ;;
  esac
}

# nyann::redact_url <url>
# Strip embedded credentials from a URL. `https://token@host/...` →
# `https://***@host/...`. Used before surfacing URLs in logs / error
# JSON so tokens don't leak when git fetch/clone fails.
nyann::redact_url() {
  printf '%s' "${1-}" | sed 's#://[^/@ ]*@#://***@#g'
}

# nyann::safe_md_cell <value>
# Sanitize a value destined for a Markdown table cell in CLAUDE.md or
# any heredoc-generated doc: strip newlines/CR, replace pipe (would
# break the cell boundary) with its HTML entity, and neutralise
# `<!-- nyann:end -->` / `<!-- nyann:start -->` / `-->` / `<!--` so
# profile values can't prematurely close or re-open the nyann marker
# region and inject content outside it.
#
# Escape `&` → `&amp;` FIRST, before any entity-emitting substitution
# runs. Without this the helper isn't idempotent: a value already
# containing `&#124;` passes through unchanged and the markdown
# renderer decodes it back to `|` on display. The order matters: `&`
# must be replaced before we emit `&#124;` / `&lt;` / `&gt;` below or
# we'd double-escape our own outputs.
nyann::safe_md_cell() {
  printf '%s' "${1-}" \
    | tr -d '\r' \
    | tr '\n' ' ' \
    | sed -e 's/&/\&amp;/g' \
          -e 's/|/\&#124;/g' \
          -e 's/<!--/\&lt;!--/g' \
          -e 's/-->/--\&gt;/g'
}

# nyann::safe_md_link_target <value>
# Sanitize a value destined for the TARGET position of a Markdown link
# (`[text](TARGET)`). Extends safe_md_cell by percent-encoding `(` and
# `)` so an unbalanced paren can't close the link early. Separate from
# safe_md_cell because percent-encoding parens in a plain table cell
# would render as `%28`/`%29` literals — fine inside URLs, ugly in
# prose like `feat(api)`. Without this helper, a DocumentationPlan
# entry whose `link_in_claude_md` contained `)` broke the docs-map
# link, and a `memory.path` with `)` broke the Memory section link —
# a correctness/UX gap rather than a security one.
nyann::safe_md_link_target() {
  nyann::safe_md_cell "${1-}" \
    | sed -e 's/(/%28/g' \
          -e 's/)/%29/g'
}

# nyann::lock <lockdir> [timeout_seconds]
# Acquire a portable advisory lock via atomic `mkdir`. Works on both
# macOS (no flock) and Linux (which has flock but the approaches don't
# mix well when other scripts may hold either lock style). Caller is
# responsible for `nyann::unlock` on their own exit paths — we do NOT
# trap here because callers often want their own cleanup sequence.
# Default timeout 10s; exits via nyann::die if the lock isn't free.
#
# On acquire, write `<pid> <host>` into `$lockdir/owner` so an
# operator triaging a stuck lock knows which process to kill.
# Writing a single file into the lockdir is still safe because
# `nyann::unlock` removes the file before `rmdir`.
nyann::lock() {
  local lockdir="$1" timeout="${2-10}"
  local waited=0
  local host
  host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)
  while ! mkdir "$lockdir" 2>/dev/null; do
    if (( waited >= timeout * 10 )); then
      local owner=""
      [[ -r "$lockdir/owner" ]] && owner=$(head -c 200 "$lockdir/owner" 2>/dev/null | tr -d '\r\n')
      if [[ -n "$owner" ]]; then
        nyann::die "timed out (${timeout}s) waiting for lock: $lockdir (held by $owner; if stale, remove $lockdir by hand)"
      else
        nyann::die "timed out (${timeout}s) waiting for lock: $lockdir"
      fi
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # Best-effort metadata write; if it fails (disk full, racey unlock)
  # the lock still works — the diagnostic is a nice-to-have.
  printf '%s %s\n' "$$" "$host" > "$lockdir/owner" 2>/dev/null || true
}

nyann::unlock() {
  local lockdir="${1-}"
  [[ -z "$lockdir" ]] && return 0
  rm -f "$lockdir/owner" 2>/dev/null || true
  rmdir "$lockdir" 2>/dev/null || true
}

# nyann::resolve_identity <target>
# Populate shell-global variables NYANN_GIT_EMAIL + NYANN_GIT_NAME with
# the target repo's configured git identity, falling back to the
# nyann@local / nyann placeholder only when nothing is configured.
# Honouring the configured identity matters for org-level "all commits
# attributed/signed" policies — bootstrap-seeded commits otherwise
# slip through unattributed.
nyann::resolve_identity() {
  local target="$1"
  # `git config` returns raw value bytes. A stray `\r`
  # or `\n` (rare but valid in a git config value) would splice into
  # `--author="$NAME <$EMAIL>"` downstream and produce a malformed
  # commit author — or worse, inject another command-line argument
  # once bash re-tokenises. Strip CR/LF defensively at the read site
  # so every caller sees single-line values.
  NYANN_GIT_EMAIL=$(git -C "$target" config user.email 2>/dev/null | tr -d '\r\n' || echo "")
  NYANN_GIT_NAME=$(git -C "$target" config user.name 2>/dev/null | tr -d '\r\n' || echo "")
  [[ -z "$NYANN_GIT_EMAIL" ]] && NYANN_GIT_EMAIL="nyann@local"
  [[ -z "$NYANN_GIT_NAME"  ]] && NYANN_GIT_NAME="nyann"
  # Explicit success so the last `[[ ]] && x` short-circuit doesn't
  # make the function return non-zero under `set -e` when the value
  # was already set (which is the happy path).
  return 0
}

# --- CLAUDE.md size thresholds ------------------------------------------------
# The soft cap is profile-configurable (profile.documentation
# .claude_md_size_budget_kb, default 3 KB). The hard cap is a plugin-
# wide constant — "CLAUDE.md is ≤ 3 KB soft, 8 KB hard" per the spec.
# Kept here so check-claude-md-size and gen-claudemd agree byte-for-
# byte; they diverged previously (one used 2*budget, the other fixed
# 8192) which produced false "critical" entries in DriftReport for
# files the writer considered valid.
# shellcheck disable=SC2034  # Consumed by check-claude-md-size.sh and
# gen-claudemd.sh via `source _lib.sh`; shellcheck doesn't follow
# sources by default so it flags this as unused.
readonly NYANN_CLAUDEMD_HARD_CAP_BYTES=8192

# --- Exclusion glob loading (shared by check-staleness.sh, find-orphans.sh) ---

# Global array populated by nyann::load_globs. Scripts that use
# nyann::is_excluded must initialise `exclusions=()` before calling.
nyann::load_globs() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    exclusions+=("$trimmed")
  done < "$f"
}

nyann::is_excluded() {
  local base="$1" rel="$2" g
  [[ ${#exclusions[@]} -eq 0 ]] && return 1
  for g in "${exclusions[@]}"; do
    # shellcheck disable=SC2254
    case "$base" in $g) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$rel"  in $g) return 0 ;; esac
  done
  return 1
}

# --- Profile schema version ---------------------------------------------------
# Single source of truth for the current profile schemaVersion.
# shellcheck disable=SC2034
readonly NYANN_CURRENT_SCHEMA=1
