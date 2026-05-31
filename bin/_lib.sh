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

  # Special-case root: when target is "/", the second pattern becomes
  # the literal `//*`, which only matches strings starting with `//`,
  # not real absolute paths. Anything resolves under "/" by definition.
  if [[ "$resolved_target" == "/" ]]; then
    printf '%s\n' "$result"
    return 0
  fi

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

# nyann::safe_mkdir_under_target <target> <rel_dir>
# Create <target>/<rel_dir> safely. Walks each path component from
# <target> down to the destination and refuses if ANY component is a
# symlink — the leaf `-L` check in writers only catches symlinked
# destinations, not symlinked ancestors. `mkdir -p` happily follows
# intermediate symlinks; without this guard, a pre-placed
# `<target>/.github → /etc/` symlink would redirect generated config
# writes outside the target tree. After the mkdir, re-canonicalises
# and verifies the resolved path still lives under <target> so a TOCTOU
# between the walk and the mkdir can't escape either.
#
# Prints the absolute path of the created directory on success. On
# refusal, prints a warning to stderr and returns 1 — caller decides
# whether to die or skip.
nyann::safe_mkdir_under_target() {
  local target="$1" rel_dir="$2"
  local full="$target/$rel_dir"
  local walk="$target" seg
  local ifs_save="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  set -- $rel_dir
  IFS="$ifs_save"
  for seg in "$@"; do
    [[ -z "$seg" ]] && continue
    walk="$walk/$seg"
    if [[ -L "$walk" ]]; then
      nyann::warn "refusing safe_mkdir: intermediate component is a symlink: $walk"
      return 1
    fi
  done
  mkdir -p "$full" || {
    nyann::warn "safe_mkdir: mkdir failed for $rel_dir under $target"
    return 1
  }
  if ! nyann::path_under_target "$target" "$full" >/dev/null 2>&1; then
    nyann::warn "safe_mkdir: resolved path escapes target after creation: $rel_dir"
    return 1
  fi
  printf '%s\n' "$full"
  return 0
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
    https://*|ssh://*|git@*|file://*) return 0 ;;
    git://*) nyann::warn "git:// protocol is unauthenticated and unencrypted — use https:// or ssh://"; return 1 ;;
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

# --- Preferences schema version ----------------------------------------------
# Current preferences.json schemaVersion. v2 carries git_identity,
# session_triage, guard_default_severity, and notifications.{sentinel,
# staleness_alerts}; v1 omits those four blocks.
# shellcheck disable=SC2034
readonly NYANN_PREFS_CURRENT_SCHEMA=2

# nyann::require_setup [skill_name]
# Returns 0 if preferences.json exists at $NYANN_USER_ROOT (default:
# ~/.claude/nyann). Returns 2 if missing — caller is expected to either
# auto-launch the setup skill inline or emit a clear "run /nyann:setup"
# hint. Honors CI / NYANN_NONINTERACTIVE by synthesizing a defaults-only
# preferences.json rather than blocking, so headless flows don't deadlock.
#
# Why a gate rather than an enforcer:
# - Bash scripts can't run the AskUserQuestion picker themselves; only the
#   surrounding skill (the LLM-driven flow) can. So this helper exits with
#   status 2 + a clear stderr hint, leaving the skill to re-enter setup.
# - In CI / NYANN_NONINTERACTIVE=true, we synthesize a defaults-only
#   preferences.json so downstream scripts don't break.
nyann::require_setup() {
  local skill="${1-}"
  local root="${NYANN_USER_ROOT:-${HOME}/.claude/nyann}"
  local prefs="$root/preferences.json"
  if [[ -f "$prefs" ]]; then
    return 0
  fi
  if [[ "${CI:-}" == "true" || "${NYANN_NONINTERACTIVE:-}" == "true" ]]; then
    # Synthesize defaults silently. We don't try to be clever about git
    # identity here — it'll come from `git config` on demand.
    mkdir -p "$root/profiles" "$root/cache" 2>/dev/null || true
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg ts "$ts" --argjson v "${NYANN_PREFS_CURRENT_SCHEMA}" '{
        schemaVersion: $v,
        default_profile: "auto-detect",
        branching_strategy: "auto-detect",
        commit_format: "conventional-commits",
        gh_integration: false,
        documentation_storage: "local",
        auto_sync_team_profiles: false,
        session_triage: true,
        guard_default_severity: "advisory",
        notifications: { sentinel: true, staleness_alerts: true },
        setup_completed_at: $ts
      }' > "$prefs" 2>/dev/null || return 2
      nyann::log "non-interactive mode — wrote default preferences to $prefs"
      return 0
    fi
    return 2
  fi
  if [[ -n "$skill" ]]; then
    nyann::warn "nyann setup required before running '$skill' — run /nyann:setup"
  else
    nyann::warn "nyann setup required — run /nyann:setup"
  fi
  return 2
}

# nyann::prefs_schema_version
# Print the schemaVersion of the user's preferences.json, or 0 if missing.
nyann::prefs_schema_version() {
  local root="${NYANN_USER_ROOT:-${HOME}/.claude/nyann}"
  local prefs="$root/preferences.json"
  [[ -f "$prefs" ]] || { printf '0\n'; return; }
  jq -r '.schemaVersion // 1' "$prefs" 2>/dev/null || printf '1\n'
}

# --- URL encoding helper -----------------------------------------------------
# Percent-encode the common path-unsafe characters we routinely see in
# Obsidian vault names and folder paths (spaces, hash, question mark,
# percent). NOT a full RFC 3986 encoder — kept narrow so it's
# deterministic and bash 3.2-portable. Order matters: encode `%` first
# so the substitutions for other chars don't get re-encoded.
nyann::url_encode_path() {
  local s="$1"
  s="${s//%/%25}"
  s="${s// /%20}"
  s="${s//\#/%23}"
  s="${s//\?/%3F}"
  printf '%s' "$s"
}

# --- Drift scope categories (v1.7.0) -----------------------------------------
# Single source of truth for the names compute-drift / retrofit / doctor /
# bootstrap accept on --scope. The list MUST match drift-report.schema.json's
# `scope_applied[]` enum.
#
# nyann::scope_includes <category> <scope_csv>
#   Returns 0 if <scope_csv> is empty, "all", or contains <category>.
#   The empty-string case lets callers default the variable to "" and still
#   get the all-categories pass-through without a separate sentinel.
nyann::scope_includes() {
  local cat="$1" scope="${2-}"
  [[ -z "$scope" || "$scope" == "all" ]] && return 0
  local IFS=','
  local s
  # shellcheck disable=SC2206  # intentional word-split on the CSV
  local arr=($scope)
  for s in "${arr[@]}"; do
    [[ "$s" == "all" || "$s" == "$cat" ]] && return 0
  done
  return 1
}

# nyann::valid_scope_csv <csv>
#   Returns 0 iff every comma-separated entry is a known category.
#   Prints the FIRST offending entry (no newline) for the caller to surface.
#   "all" is allowed alongside other categories — semantically redundant but
#   harmless, and rejecting it would force callers to pre-strip.
nyann::valid_scope_csv() {
  local csv="${1-}"
  [[ -z "$csv" ]] && { printf '<empty>'; return 1; }
  local IFS=','
  local s
  # shellcheck disable=SC2206
  local arr=($csv)
  for s in "${arr[@]}"; do
    case "$s" in
      docs|hooks|branching|gitignore|editorconfig|github|history|all) ;;
      *) printf '%s' "$s"; return 1 ;;
    esac
  done
  return 0
}

# nyann::canonical_scope <csv>
#   Emits the canonical scope CSV: deduplicated, sorted, with "all"
#   collapsed to "all" (any "all" entry overrides everything else).
#   Used to normalize compute-drift's scope_applied[] output.
nyann::canonical_scope() {
  local csv="${1-all}"
  [[ -z "$csv" ]] && csv="all"
  local IFS=','
  local s
  # shellcheck disable=SC2206
  local arr=($csv)
  for s in "${arr[@]}"; do
    [[ "$s" == "all" ]] && { printf 'all'; return 0; }
  done
  printf '%s\n' "${arr[@]}" | sort -u | paste -sd, -
}

# --- Archetype scaffold map (v1.6.0) -----------------------------------------
# Single source of truth for the per-archetype Project Memory scaffold
# set. Both bin/route-docs.sh (planner) and bin/scaffold-docs.sh
# (materializer) consume this so the two stay in lockstep when a new
# archetype or doc type is introduced.
#
# Output: lines of `<doc-type>:<conventional-local-path>` for the
# requested archetype. Callers iterate via `IFS=:`.
nyann::archetype_scaffold_map() {
  case "$1" in
    api-service)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'api_reference:docs/api-reference.md' \
        'runbook:docs/runbook.md' \
        'deployment:docs/deployment.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    cli-tool)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'runbook:docs/runbook.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    library)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'api_reference:docs/api-reference.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    web-app)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'runbook:docs/runbook.md' \
        'deployment:docs/deployment.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    mobile-app)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'runbook:docs/runbook.md' \
        'deployment:docs/deployment.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    plugin)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    infra)
      # IaC monorepo (Terraform / CDK / Pulumi / Helm / Kustomize). The
      # 'modules' scaffold type is new for this archetype: it produces
      # docs/modules/README.md as a per-module index template, materialized
      # by scaffold-docs.sh.
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'runbook:docs/runbook.md' \
        'deployment:docs/deployment.md' \
        'adrs:docs/decisions' \
        'glossary:docs/glossary.md'
      ;;
    *)
      # unknown / unset → match pre-v1.6.0 default (architecture + adrs)
      printf '%s\n' \
        'architecture:docs/architecture.md' \
        'adrs:docs/decisions'
      ;;
  esac
}

# Convenience: emit just the type list (no paths) for callers that
# need to iterate scaffold types only (e.g., route-docs.sh's iter set).
nyann::archetype_scaffold_types() {
  nyann::archetype_scaffold_map "$1" | cut -d: -f1
}
