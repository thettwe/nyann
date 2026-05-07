#!/usr/bin/env bash
# setup.sh — create the nyann user directory structure and write preferences.
#
# Usage: setup.sh [options]
#
# Options:
#   --user-root <dir>            Override ~/.claude/nyann (testing)
#   --default-profile <name>     Default profile (default: auto-detect)
#   --branching-strategy <s>     auto-detect|github-flow|gitflow|trunk-based
#   --commit-format <f>          conventional-commits|custom
#   --gh-integration             Enable GitHub CLI integration (default)
#   --no-gh-integration          Disable GitHub CLI integration
#   --documentation-storage <s>  local|obsidian|notion
#   --auto-sync-team-profiles    Auto-sync team sources during bootstrap
#   --no-auto-sync-team-profiles Disable auto-sync (default)
#   --json                       Emit result as JSON instead of human table
#   --check                      Report current state without writing anything
#   --simulate <repo>            Simulate `/nyann:bootstrap` on <repo> using
#                                the current (in-flight or saved) preferences
#                                and report what would happen. No mutations.
#
# Exit codes:
#   0 — setup completed (or --check: preferences exist; or --simulate: ok)
#   1 — hard error (missing jq, bad input)
#   2 — --check: no preferences.json found yet

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

user_root="${HOME}/.claude/nyann"
json_out=false
check_only=false
simulate_target=""

default_profile="auto-detect"
branching_strategy="auto-detect"
commit_format="conventional-commits"
gh_integration=true
documentation_storage="local"
auto_sync_team_profiles=false

# Track which flags the caller explicitly set. --simulate falls back
# to preferences.json for any flag the caller did NOT override, which
# is what the docs promise ("in-flight or saved"). Without these
# sentinels, --simulate couldn't distinguish "user wants the default"
# from "user said nothing, so use saved prefs".
_set_default_profile=false
_set_branching_strategy=false
_set_commit_format=false
_set_gh_integration=false
_set_documentation_storage=false
_set_auto_sync_team_profiles=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)                  user_root="${2:-}"; shift 2 ;;
    --user-root=*)                user_root="${1#--user-root=}"; shift ;;
    --default-profile)            default_profile="${2:-}"; _set_default_profile=true; shift 2 ;;
    --default-profile=*)          default_profile="${1#--default-profile=}"; _set_default_profile=true; shift ;;
    --branching-strategy)         branching_strategy="${2:-}"; _set_branching_strategy=true; shift 2 ;;
    --branching-strategy=*)       branching_strategy="${1#--branching-strategy=}"; _set_branching_strategy=true; shift ;;
    --commit-format)              commit_format="${2:-}"; _set_commit_format=true; shift 2 ;;
    --commit-format=*)            commit_format="${1#--commit-format=}"; _set_commit_format=true; shift ;;
    --gh-integration)             gh_integration=true; _set_gh_integration=true; shift ;;
    --no-gh-integration)          gh_integration=false; _set_gh_integration=true; shift ;;
    --documentation-storage)      documentation_storage="${2:-}"; _set_documentation_storage=true; shift 2 ;;
    --documentation-storage=*)    documentation_storage="${1#--documentation-storage=}"; _set_documentation_storage=true; shift ;;
    --auto-sync-team-profiles)    auto_sync_team_profiles=true; _set_auto_sync_team_profiles=true; shift ;;
    --no-auto-sync-team-profiles) auto_sync_team_profiles=false; _set_auto_sync_team_profiles=true; shift ;;
    --simulate)                   simulate_target="${2:-}"; shift 2 ;;
    --simulate=*)                 simulate_target="${1#--simulate=}"; shift ;;
    --json)                       json_out=true; shift ;;
    --check)                      check_only=true; shift ;;
    -h|--help)                    sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                            nyann::die "unknown argument: $1" ;;
  esac
done

# --- Validation ---------------------------------------------------------------

case "$branching_strategy" in
  auto-detect|github-flow|gitflow|trunk-based) ;;
  *) nyann::die "invalid --branching-strategy: $branching_strategy (expected auto-detect|github-flow|gitflow|trunk-based)" ;;
esac

case "$commit_format" in
  conventional-commits|custom) ;;
  *) nyann::die "invalid --commit-format: $commit_format (expected conventional-commits|custom)" ;;
esac

case "$documentation_storage" in
  local|obsidian|notion) ;;
  *) nyann::die "invalid --documentation-storage: $documentation_storage (expected local|obsidian|notion)" ;;
esac

if [[ "$default_profile" != "auto-detect" ]]; then
  if ! [[ "$default_profile" =~ ^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)?$ ]]; then
    nyann::die "invalid --default-profile: $default_profile (must be 'auto-detect' or a valid profile name)"
  fi
fi

# --- Simulate mode -----------------------------------------------------------
# Runs detection + suggestion + planning against $simulate_target without
# touching anything. Lets the operator validate setup preferences against
# a real repo before running /nyann:bootstrap. No persistence, no
# preferences are written.

if [[ -n "$simulate_target" ]]; then
  [[ -d "$simulate_target" ]] || nyann::die "--simulate target is not a directory: $simulate_target"
  simulate_target="$(cd "$simulate_target" && pwd)"

  sim_tmp=$(mktemp -d -t nyann-simulate.XXXXXX)
  trap 'rm -rf "$sim_tmp"' EXIT

  # Documented contract: simulate honours "in-flight or saved"
  # preferences. For any flag the caller did NOT override, fall back
  # to the saved preferences.json (when present). Without this fallback
  # users hit a confusing path where their saved Notion routing /
  # custom profile was ignored and simulate auto-detected fresh.
  saved_prefs="${user_root}/preferences.json"
  if [[ -f "$saved_prefs" ]]; then
    if ! $_set_default_profile; then
      v=$(jq -r '.default_profile // empty' "$saved_prefs" 2>/dev/null || true)
      [[ -n "$v" ]] && default_profile="$v"
    fi
    if ! $_set_branching_strategy; then
      v=$(jq -r '.branching_strategy // empty' "$saved_prefs" 2>/dev/null || true)
      [[ -n "$v" ]] && branching_strategy="$v"
    fi
    if ! $_set_commit_format; then
      v=$(jq -r '.commit_format // empty' "$saved_prefs" 2>/dev/null || true)
      [[ -n "$v" ]] && commit_format="$v"
    fi
    if ! $_set_gh_integration; then
      v=$(jq -r '.gh_integration // empty' "$saved_prefs" 2>/dev/null || true)
      [[ "$v" == "false" ]] && gh_integration=false
      [[ "$v" == "true"  ]] && gh_integration=true
    fi
    if ! $_set_documentation_storage; then
      v=$(jq -r '.documentation_storage // empty' "$saved_prefs" 2>/dev/null || true)
      [[ -n "$v" ]] && documentation_storage="$v"
    fi
    if ! $_set_auto_sync_team_profiles; then
      v=$(jq -r '.auto_sync_team_profiles // empty' "$saved_prefs" 2>/dev/null || true)
      [[ "$v" == "false" ]] && auto_sync_team_profiles=false
      [[ "$v" == "true"  ]] && auto_sync_team_profiles=true
    fi
  fi

  # 1. Detect stack
  if ! "${_script_dir}/detect-stack.sh" --path "$simulate_target" > "$sim_tmp/stack.json" 2> "$sim_tmp/detect.err"; then
    cat "$sim_tmp/detect.err" >&2
    nyann::die "stack detection failed for $simulate_target"
  fi

  stack_lang=$(jq -r '.primary_language' "$sim_tmp/stack.json")
  stack_framework=$(jq -r '.framework // "(none)"' "$sim_tmp/stack.json")
  stack_archetype=$(jq -r '.archetype // "unknown"' "$sim_tmp/stack.json")
  stack_confidence=$(jq -r '.confidence // 0' "$sim_tmp/stack.json")
  stack_monorepo=$(jq -r '.is_monorepo // false' "$sim_tmp/stack.json")

  # 2. Resolve profile (use --default-profile, or suggest)
  resolved_profile=""
  resolved_confidence=""
  if [[ "$default_profile" != "auto-detect" ]]; then
    resolved_profile="$default_profile"
    resolved_confidence="100"
  else
    if "${_script_dir}/suggest-profile.sh" --target "$simulate_target" --stack "$sim_tmp/stack.json" > "$sim_tmp/suggest.json" 2>/dev/null; then
      resolved_profile=$(jq -r '.primary.name // "default"' "$sim_tmp/suggest.json")
      resolved_confidence=$(jq -r '.primary.confidence // 0' "$sim_tmp/suggest.json")
    else
      resolved_profile="default"
      resolved_confidence="0"
    fi
  fi

  if ! "${_script_dir}/load-profile.sh" "$resolved_profile" > "$sim_tmp/profile.json" 2> "$sim_tmp/load.err"; then
    cat "$sim_tmp/load.err" >&2
    nyann::die "failed to load profile: $resolved_profile"
  fi

  # 3. Recommend branching (only when user said auto-detect)
  resolved_branching="$branching_strategy"
  if [[ "$branching_strategy" == "auto-detect" ]]; then
    if "${_script_dir}/recommend-branch.sh" < "$sim_tmp/stack.json" > "$sim_tmp/branch.json" 2>/dev/null; then
      resolved_branching=$(jq -r '.recommended // "github-flow"' "$sim_tmp/branch.json")
    else
      resolved_branching="github-flow"
    fi
  fi

  # 4. Route docs. When the resolved preference (in-flight or saved)
  # asks for a non-local backend, propagate via `--routing all:<backend>`
  # so the simulated DocumentationPlan reflects the same routing the
  # actual bootstrap would compose. `memory` is always local per nyann
  # invariant; route-docs honours that regardless of the spec.
  #
  # route-docs refuses a non-local spec unless the backend appears in
  # --mcp-targets.available. Simulation is meant to preview the user's
  # *intended* configuration, so we synthesize an mcp-targets file
  # marking the requested backend available. The real bootstrap path
  # uses bin/detect-mcp-docs.sh (driven by Claude Code settings) and
  # will surface a real MCP gap to the user there.
  route_args=(--profile "$sim_tmp/profile.json")
  case "$documentation_storage" in
    obsidian|notion)
      mcp_synth="$sim_tmp/mcp-targets.json"
      # available[] entries are objects with a `type` field, not bare
      # strings — route-docs reads them via `.available[].type`.
      jq -n --arg backend "$documentation_storage" \
        '{settings_path: "(simulated)", available: [{type: $backend, server: "(simulated)"}], configured_but_disabled: [], unknown_servers_skipped: []}' \
        > "$mcp_synth"
      route_args+=(--mcp-targets "$mcp_synth" --routing "all:${documentation_storage}")
      # route-docs requires --obsidian-vault / --notion-parent for the
      # respective backends. Pass synthetic placeholders so simulation
      # reaches the planner — bootstrap will collect real values from
      # the user via the bootstrap-project skill.
      case "$documentation_storage" in
        obsidian) route_args+=(--obsidian-vault "(simulated)") ;;
        notion)   route_args+=(--notion-parent "(simulated)") ;;
      esac
      ;;
    local|"") ;;
  esac
  if ! "${_script_dir}/route-docs.sh" "${route_args[@]}" > "$sim_tmp/doc-plan.json" 2> "$sim_tmp/route.err"; then
    cat "$sim_tmp/route.err" >&2
    nyann::die "doc routing failed"
  fi

  # 5. Compose plan
  partial=false
  if [[ "$stack_monorepo" == "true" ]]; then
    partial=true
  fi
  if ! "${_script_dir}/plan-bootstrap.sh" \
        --target "$simulate_target" \
        --profile "$sim_tmp/profile.json" \
        --doc-plan "$sim_tmp/doc-plan.json" \
        --stack "$sim_tmp/stack.json" \
        --branching "$resolved_branching" \
        > "$sim_tmp/plan.json" 2> "$sim_tmp/plan.err"; then
    cat "$sim_tmp/plan.err" >&2
    nyann::die "plan composition failed"
  fi

  # 6. Render
  write_count=$(jq '.writes | length' "$sim_tmp/plan.json")
  has_git_init=$(jq '[.commands[] | select(.cmd == "git init")] | length > 0' "$sim_tmp/plan.json")
  merge_count=$(jq '[.writes[] | select(.action == "merge")] | length' "$sim_tmp/plan.json")
  create_count=$(jq '[.writes[] | select(.action == "create")] | length' "$sim_tmp/plan.json")

  if $json_out; then
    jq -n \
      --arg target "$simulate_target" \
      --slurpfile stack "$sim_tmp/stack.json" \
      --arg profile "$resolved_profile" \
      --arg profile_confidence "$resolved_confidence" \
      --arg branching "$resolved_branching" \
      --slurpfile plan "$sim_tmp/plan.json" \
      --argjson partial "$partial" \
      '{
        simulation: (if $partial then "partial" else "ok" end),
        target: $target,
        stack: $stack[0],
        profile: { name: $profile, confidence: ($profile_confidence | tonumber) },
        branching: $branching,
        plan: $plan[0],
        partial_reason: (if $partial then "monorepo (per-workspace writes are added by the skill)" else null end)
      }'
  else
    {
      printf '\nSimulation: %s\n' "$simulate_target"
      printf -- '─────────────────────────────────\n'
      printf 'Detected:  %s + %s (confidence %s)\n' "$stack_lang" "$stack_framework" "$stack_confidence"
      printf 'Archetype: %s\n' "$stack_archetype"
      printf 'Profile:   %s (confidence %s)\n' "$resolved_profile" "$resolved_confidence"
      printf 'Branching: %s\n' "$resolved_branching"
      printf '\nIf you ran /nyann:bootstrap here, it would:\n'
      printf '  - Write %s file(s) — %s create, %s merge\n' "$write_count" "$create_count" "$merge_count"
      if [[ "$has_git_init" == "true" ]]; then
        # Backticks are literal markdown for the user, not command
        # substitution. Single-quoting is intentional.
        # shellcheck disable=SC2016
        printf '  - Run `git init`\n'
      fi
      if $partial; then
        printf '\n⚠ Monorepo detected. Per-workspace writes (lint-staged, commit\n'
        printf '  scopes) are added by the skill on top of this base plan.\n'
      fi
      printf '\nNo changes made — this was a simulation.\n'
    } >&2
  fi

  exit 0
fi

# --- Check mode ---------------------------------------------------------------

prefs_path="${user_root}/preferences.json"

if $check_only; then
  if [[ ! -f "$prefs_path" ]]; then
    if $json_out; then
      jq -n '{"status":"not_configured","preferences_path":$p,"user_root":$r,"directories":{"profiles":($r+"/profiles"),"cache":($r+"/cache")}}' \
        --arg p "$prefs_path" --arg r "$user_root"
    else
      printf '\nnyann setup status: not configured\n\n'
      printf '  preferences file:  %s (not found)\n' "$prefs_path"
      printf '  user root:         %s\n' "$user_root"
      printf '\nRun /nyann:setup to configure.\n'
    fi
    exit 0
  fi

  existing=$(cat "$prefs_path")
  dirs_ok=true
  [[ -d "${user_root}/profiles" ]] || dirs_ok=false
  [[ -d "${user_root}/cache" ]] || dirs_ok=false

  if $json_out; then
    jq -n --argjson prefs "$existing" --argjson dirs_ok "$dirs_ok" \
      '{"status":"configured","preferences":$prefs,"directories_ok":$dirs_ok}'
  else
    printf '\nnyann setup status: configured\n\n'
    printf '  %-26s %s\n' "default_profile:" "$(jq -r '.default_profile // "auto-detect"' <<<"$existing")"
    printf '  %-26s %s\n' "branching_strategy:" "$(jq -r '.branching_strategy // "auto-detect"' <<<"$existing")"
    printf '  %-26s %s\n' "commit_format:" "$(jq -r '.commit_format // "conventional-commits"' <<<"$existing")"
    printf '  %-26s %s\n' "gh_integration:" "$(jq -r '.gh_integration // true' <<<"$existing")"
    printf '  %-26s %s\n' "documentation_storage:" "$(jq -r '.documentation_storage // "local"' <<<"$existing")"
    printf '  %-26s %s\n' "auto_sync_team_profiles:" "$(jq -r '.auto_sync_team_profiles // false' <<<"$existing")"
    printf '  %-26s %s\n' "setup_completed_at:" "$(jq -r '.setup_completed_at // "unknown"' <<<"$existing")"
    printf '\n  directories ok:  %s\n' "$dirs_ok"
  fi
  exit 0
fi

# --- Create directory structure -----------------------------------------------

old_umask=$(umask)
umask 0077

mkdir -p "${user_root}/profiles" 2>/dev/null || true
mkdir -p "${user_root}/cache" 2>/dev/null || true

umask "$old_umask"

# --- Write preferences --------------------------------------------------------

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

prefs_tmp=$(mktemp -t nyann-prefs.XXXXXX)
trap 'rm -f "$prefs_tmp"' EXIT

jq -n \
  --argjson schema_version 1 \
  --arg default_profile "$default_profile" \
  --arg branching_strategy "$branching_strategy" \
  --arg commit_format "$commit_format" \
  --argjson gh_integration "$gh_integration" \
  --arg documentation_storage "$documentation_storage" \
  --argjson auto_sync_team_profiles "$auto_sync_team_profiles" \
  --arg setup_completed_at "$timestamp" \
  '{
    schemaVersion: $schema_version,
    default_profile: $default_profile,
    branching_strategy: $branching_strategy,
    commit_format: $commit_format,
    gh_integration: $gh_integration,
    documentation_storage: $documentation_storage,
    auto_sync_team_profiles: $auto_sync_team_profiles,
    setup_completed_at: $setup_completed_at
  }' > "$prefs_tmp"

[[ -L "$prefs_path" ]] && nyann::die "refusing to write preferences via symlink: $prefs_path"
mv "$prefs_tmp" "$prefs_path"

chmod 600 "$prefs_path" 2>/dev/null || true

$json_out || nyann::log "preferences written to ${prefs_path}"

# --- Output -------------------------------------------------------------------

if $json_out; then
  jq -n \
    --arg prefs_path "$prefs_path" \
    --arg user_root "$user_root" \
    --slurpfile prefs "$prefs_path" \
    '{
      status: "ok",
      preferences_path: $prefs_path,
      user_root: $user_root,
      preferences: $prefs[0],
      directories: {
        profiles: ($user_root + "/profiles"),
        cache: ($user_root + "/cache")
      }
    }'
else
  printf '\nnyann setup complete\n\n'
  printf '  %-26s %s\n' "preferences:" "$prefs_path"
  printf '  %-26s %s\n' "profiles dir:" "${user_root}/profiles"
  printf '  %-26s %s\n' "cache dir:" "${user_root}/cache"
  printf '\n  Preferences:\n'
  printf '  %-26s %s\n' "default_profile:" "$default_profile"
  printf '  %-26s %s\n' "branching_strategy:" "$branching_strategy"
  printf '  %-26s %s\n' "commit_format:" "$commit_format"
  printf '  %-26s %s\n' "gh_integration:" "$gh_integration"
  printf '  %-26s %s\n' "documentation_storage:" "$documentation_storage"
  printf '  %-26s %s\n' "auto_sync_team_profiles:" "$auto_sync_team_profiles"
fi
