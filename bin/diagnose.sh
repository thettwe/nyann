#!/usr/bin/env bash
# diagnose.sh — bundle a support-grade snapshot of the current nyann state.
#
# Usage:
#   diagnose.sh [--target <repo>] [--profile <name>]
#               [--user-root <dir>] [--json]
#
# Default mode prints a human-readable summary to stdout. With --json,
# emits a single DiagnoseBundle JSON object that includes:
#   - nyann_version (from .claude-plugin/plugin.json)
#   - host (uname, bash version, jq/git/gh versions)
#   - repo (explain-state output: stack, profile, branching, hooks,
#     CLAUDE.md presence + size, current branch, recent commits)
#   - health (compute-drift summary; nyann::doctor without --persist)
#   - git_config (git config --list, with embedded URL credentials
#     redacted via nyann::redact_url)
#   - hook_files (contents of .git/hooks/pre-commit, commit-msg,
#     .husky/* if present)
#   - nyann_config (preferences.json + team_profile_sources[] with URLs
#     redacted)
#   - prereqs (check-prereqs --json output)
#
# Designed for the "user reports nyann broke on my repo" support flow:
# the maintainer asks for the bundle output, and it contains everything
# needed to reproduce or pinpoint the problem. NEVER emits raw secrets:
# every URL passes through nyann::redact_url; tokens stripped from env.
#
# Read-only. Never mutates the target repo or user config.
#
# Exit codes:
#   0 — bundle emitted
#   2 — target not a directory / not a git repo

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
profile_name=""
user_root="${HOME}/.claude/nyann"
json_out=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)      target="${2:-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --profile)     profile_name="${2:-}"; shift 2 ;;
    --profile=*)   profile_name="${1#--profile=}"; shift ;;
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    --json)        json_out=true; shift ;;
    -h|--help)     sed -n '3,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target must be a directory: $target"
target="$(cd "$target" && pwd)"

plugin_root="$(cd "${_script_dir}/.." && pwd)"

# --- nyann_version -----------------------------------------------------------

nyann_version="unknown"
if [[ -f "${plugin_root}/.claude-plugin/plugin.json" ]]; then
  nyann_version=$(jq -r '.version // "unknown"' "${plugin_root}/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown")
fi

# --- host info ---------------------------------------------------------------
# Strip every env var that looks like a credential from the dump. Even
# though we don't include the env in the bundle, the safety check is
# cheap and prevents future misuse.

uname_str=$(uname -srm 2>/dev/null || echo "unknown")
bash_str="${BASH_VERSION:-unknown}"
jq_str=$(jq --version 2>/dev/null || echo "missing")
git_str=$(git --version 2>/dev/null | awk '{print $3}' || echo "missing")
gh_str="missing"
if command -v gh >/dev/null 2>&1; then
  gh_str=$(gh --version 2>/dev/null | head -1 | awk '{print $3}')
fi

host_block=$(jq -n \
  --arg uname "$uname_str" \
  --arg bash "$bash_str" \
  --arg jq "$jq_str" \
  --arg git "$git_str" \
  --arg gh "$gh_str" \
  '{uname:$uname, bash:$bash, jq:$jq, git:$git, gh:$gh}')

# --- repo block (explain-state) ---------------------------------------------

repo_block='{}'
state_args=(--target "$target" --json)
[[ -n "$profile_name" ]] && state_args+=(--profile "$profile_name")
if state_out=$("${_script_dir}/explain-state.sh" "${state_args[@]}" 2>/dev/null); then
  repo_block="$state_out"
fi

# --- health block (doctor --json, no persist) -------------------------------
# Resolve profile if not passed: prefer the one explain-state inferred,
# else default to "default".

resolved_profile="$profile_name"
if [[ -z "$resolved_profile" ]]; then
  resolved_profile=$(jq -r '.profile.name // ""' <<<"$repo_block" 2>/dev/null || echo "")
fi
[[ -z "$resolved_profile" || "$resolved_profile" == "null" ]] && resolved_profile="default"

health_block='null'
if [[ -d "$target/.git" ]]; then
  if doctor_out=$("${_script_dir}/doctor.sh" --target "$target" --profile "$resolved_profile" --json 2>/dev/null); then
    health_block="$doctor_out"
  fi
fi

# --- git_config block (REDACTED) --------------------------------------------
# git config --list dumps every key incl. remote URLs which may carry
# https://<token>@host/... auth. Pipe each value through redact_url.

git_config_lines='[]'
if [[ -d "$target/.git" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    redacted=$(nyann::redact_url "$line")
    git_config_lines=$(jq --arg l "$redacted" '. + [$l]' <<<"$git_config_lines")
  done < <(git -C "$target" config --list 2>/dev/null || true)
fi

# Working tree status (porcelain).
git_status='[]'
if [[ -d "$target/.git" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    git_status=$(jq --arg l "$line" '. + [$l]' <<<"$git_status")
  done < <(git -C "$target" status --porcelain 2>/dev/null || true)
fi

git_block=$(jq -n \
  --argjson cfg "$git_config_lines" \
  --argjson status "$git_status" \
  '{config:$cfg, status:$status}')

# --- hook_files block --------------------------------------------------------

hook_block='{}'
read_optional() {
  local p="$1"
  if [[ -f "$p" && -r "$p" ]]; then
    head -c 8192 "$p" 2>/dev/null
  fi
}

if [[ -d "$target" ]]; then
  precommit_git=$(read_optional "$target/.git/hooks/pre-commit")
  commitmsg_git=$(read_optional "$target/.git/hooks/commit-msg")
  husky_pc=$(read_optional "$target/.husky/pre-commit")
  husky_cm=$(read_optional "$target/.husky/commit-msg")
  precommit_yaml=$(read_optional "$target/.pre-commit-config.yaml")

  hook_block=$(jq -n \
    --arg gpc "$precommit_git" \
    --arg gcm "$commitmsg_git" \
    --arg hpc "$husky_pc" \
    --arg hcm "$husky_cm" \
    --arg pcy "$precommit_yaml" \
    '{
      ".git/hooks/pre-commit":        (if $gpc == "" then null else $gpc end),
      ".git/hooks/commit-msg":        (if $gcm == "" then null else $gcm end),
      ".husky/pre-commit":            (if $hpc == "" then null else $hpc end),
      ".husky/commit-msg":            (if $hcm == "" then null else $hcm end),
      ".pre-commit-config.yaml":      (if $pcy == "" then null else $pcy end)
    }')
fi

# --- nyann_config block (REDACTED) ------------------------------------------

nyann_config_block='null'
prefs_path="$user_root/preferences.json"
if [[ -f "$prefs_path" ]]; then
  prefs_json=$(cat "$prefs_path" 2>/dev/null || echo '{}')
  # Redact team-source URLs; keep the rest of the prefs as-is.
  config_path="$user_root/config.json"
  team_sources_raw='[]'
  if [[ -f "$config_path" ]]; then
    team_sources_raw=$(jq '.team_profile_sources // []' "$config_path" 2>/dev/null || echo '[]')
  fi
  # Redact each URL via a jq pipeline that calls out to nyann::redact_url
  # for every entry. jq can't shell out cleanly; do it in bash.
  redacted_sources='[]'
  count=$(jq 'length' <<<"$team_sources_raw")
  for ((i=0; i<count; i++)); do
    name=$(jq -r --arg i "$i" '.[$i|tonumber].name' <<<"$team_sources_raw")
    url=$(jq -r --arg i "$i" '.[$i|tonumber].url' <<<"$team_sources_raw")
    ref=$(jq -r --arg i "$i" '.[$i|tonumber].ref' <<<"$team_sources_raw")
    last=$(jq -r --arg i "$i" '.[$i|tonumber].last_synced_at // 0' <<<"$team_sources_raw")
    interval=$(jq -r --arg i "$i" '.[$i|tonumber].sync_interval_hours // 24' <<<"$team_sources_raw")
    url_redacted=$(nyann::redact_url "$url")
    entry=$(jq -n \
      --arg n "$name" --arg u "$url_redacted" --arg r "$ref" \
      --argjson l "$last" --argjson i "$interval" \
      '{name:$n, url:$u, ref:$r, last_synced_at:$l, sync_interval_hours:$i}')
    redacted_sources=$(jq --argjson e "$entry" '. + [$e]' <<<"$redacted_sources")
  done

  nyann_config_block=$(jq -n \
    --argjson prefs "$prefs_json" \
    --argjson sources "$redacted_sources" \
    '{preferences:$prefs, team_profile_sources:$sources}')
fi

# --- prereqs block ----------------------------------------------------------

prereqs_block='null'
if prereqs_out=$("${_script_dir}/check-prereqs.sh" --json 2>/dev/null); then
  prereqs_block="$prereqs_out"
fi

# --- assemble ---------------------------------------------------------------

bundle=$(jq -n \
  --arg version "$nyann_version" \
  --arg target "$target" \
  --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson host "$host_block" \
  --argjson repo "$repo_block" \
  --argjson health "$health_block" \
  --argjson git "$git_block" \
  --argjson hook_files "$hook_block" \
  --argjson nyann_config "$nyann_config_block" \
  --argjson prereqs "$prereqs_block" \
  '{
    nyann_version: $version,
    target: $target,
    generated_at: $generated_at,
    host: $host,
    repo: $repo,
    health: $health,
    git: $git,
    hook_files: $hook_files,
    nyann_config: $nyann_config,
    prereqs: $prereqs
  }')

if $json_out; then
  printf '%s\n' "$bundle"
  exit 0
fi

# Human-readable rendering.
{
  printf '\nnyann diagnose bundle (paste into a support request)\n\n'
  printf '  nyann version:     %s\n' "$nyann_version"
  printf '  target repo:       %s\n' "$target"
  printf '  generated at:      %s\n' "$(jq -r '.generated_at' <<<"$bundle")"
  printf '\nHost:\n'
  jq -r '.host | "  uname: \(.uname)\n  bash:  \(.bash)\n  jq:    \(.jq)\n  git:   \(.git)\n  gh:    \(.gh)"' <<<"$bundle"

  if jq -e '.repo | length > 0' <<<"$bundle" >/dev/null; then
    printf '\nRepo:\n'
    jq -r '.repo | "  branch:           \(.branch // "—")\n  primary language: \(.stack.primary_language // "—")\n  profile:          \(.profile.name // "—") (\(.profile.source // "—"))\n  branching:        \(.branching.strategy // "—") (bases: \(.branching.base_branches | join(", ") // "—"))\n  hooks present:    husky=\(.hooks.husky) pre-commit-com=\(.hooks.pre_commit_com) core=\(.hooks.core)\n  CLAUDE.md:        present=\(.claude_md.present) bytes=\(.claude_md.bytes) markers=\(.claude_md.router_markers)"' <<<"$bundle"
  fi

  if jq -e '.health' <<<"$bundle" >/dev/null && [[ "$health_block" != "null" ]]; then
    printf '\nHealth:\n'
    jq -r '.health.summary | "  missing:        \(.missing)\n  misconfigured:  \(.misconfigured)\n  broken links:   \(.broken_links)\n  CLAUDE.md:      \(.claude_md_status)"' <<<"$bundle"
    score=$(jq -r '.health.health_score.score // "—"' <<<"$bundle")
    [[ "$score" != "—" ]] && printf '  health score:   %s/100\n' "$score"
  fi

  printf '\nFor full machine-readable output: rerun with --json\n'
  printf 'Sensitive values (URL credentials, tokens) are redacted before printing.\n'
} >&2
