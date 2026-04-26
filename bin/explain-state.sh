#!/usr/bin/env bash
# explain-state.sh — aggregate what nyann "sees" in the current repo.
# Read-only summary: stack detection, active profile, branching, hook
# status, CLAUDE.md presence + size, current branch, recent commits.
#
# Usage:
#   explain-state.sh --target <repo> [--json] [--profile <name>]
#
# When --profile is omitted, the script tries to infer the active profile
# from CLAUDE.md's nyann block or a local .nyann/profile hint. Unknown
# profile is acceptable — we report what we can.
#
# Output (default: human-readable table to stdout). With --json, a
# structured summary:
#   {
#     "repo":       "/abs/path",
#     "branch":     "feat/x",
#     "stack":      { "primary_language": "...", "framework": "...", "package_manager": "..." },
#     "profile":    { "name": "...", "source": "starter|user|team|unknown" },
#     "branching":  { "strategy": "...", "base_branches": [...] },
#     "hooks":      { "husky": false, "pre_commit_com": false, "core": false },
#     "claude_md":  { "present": true, "bytes": 1234, "router_markers": true },
#     "recent_commits": [ { "sha": "...", "subject": "..." } ]
#   }
#
# Exit codes:
#   0 — state summary emitted
#   2 — target not a git repo or missing

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
json_out=false
profile_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     target="${2:-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --json)       json_out=true; shift ;;
    --profile)    profile_name="${2:-}"; shift 2 ;;
    --profile=*)  profile_name="${1#--profile=}"; shift ;;
    -h|--help)    sed -n '3,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || { nyann::warn "$target is not a git repo"; exit 2; }

# --- branch + recent commits -------------------------------------------------

branch="$(git -C "$target" branch --show-current 2>/dev/null || echo "")"

recent_json='[]'
while IFS=$'\t' read -r sha subject; do
  [[ -z "$sha" ]] && continue
  recent_json=$(jq --arg sha "$sha" --arg subject "$subject" \
    '. + [{sha:$sha, subject:$subject}]' <<<"$recent_json")
done < <(git -C "$target" log -n 5 --pretty=tformat:'%H%x09%s' 2>/dev/null || true)

# --- stack ------------------------------------------------------------------

stack_json=$("${_script_dir}/detect-stack.sh" --path "$target" 2>/dev/null || echo '{}')
stack_block=$(jq -c '{
  primary_language: (.primary_language // "unknown"),
  framework: .framework,
  package_manager: .package_manager,
  confidence: (.confidence // null)
}' <<<"$stack_json")

# --- profile ----------------------------------------------------------------
# When --profile is passed, trust it. Otherwise try to infer from CLAUDE.md.

profile_block='{"name": null, "source": "unknown"}'

infer_profile_from_claudemd() {
  local cm="$target/CLAUDE.md"
  [[ -f "$cm" ]] || return 1
  # Look for a nyann block that names the active profile.
  # Backticks in the regex are literal markdown delimiters, not shell
  # command substitution. Single-quoting is intentional.
  local name
  name=$(grep -Eo 'nyann profile[: ]+[a-z0-9][a-z0-9-]*' "$cm" 2>/dev/null | head -n1 | awk '{print $NF}' || true)
  # shellcheck disable=SC2016
  [[ -z "$name" ]] && name=$(grep -Eo 'Profile: `[a-z0-9][a-z0-9-]*`' "$cm" 2>/dev/null | head -n1 | tr -d '`' | awk '{print $NF}' || true)
  [[ -n "$name" ]] && echo "$name"
}

if [[ -z "$profile_name" ]]; then
  profile_name=$(infer_profile_from_claudemd || true)
fi

if [[ -n "$profile_name" ]]; then
  load_stderr=$(mktemp -t nyann-explain-load.XXXXXX)
  trap 'rm -f "$load_stderr"' EXIT
  profile_json=$("${_script_dir}/load-profile.sh" "$profile_name" 2>"$load_stderr") || profile_json=""
  if [[ -n "$profile_json" ]]; then
    local_source=$(grep -oE 'from (starter|user|team)' "$load_stderr" 2>/dev/null | awk '{print $2}' || true)
    : "${local_source:=loaded}"
    profile_block=$(jq -n --arg n "$profile_name" --arg s "$local_source" '{name:$n, source:$s}')
  else
    profile_block=$(jq -n --arg n "$profile_name" --arg s "unknown" '{name:$n, source:$s}')
  fi
  rm -f "$load_stderr"
fi

# --- branching --------------------------------------------------------------
# Strategy comes from the profile when known, otherwise best-effort heuristic
# (we keep this block minimal — full recommendation is in bin/recommend-branch.sh).

branching_block=$(jq -nc '{strategy: null, base_branches: []}')
if [[ -n "$profile_name" && -n "${profile_json:-}" ]]; then
  branching_block=$(jq -c '.branching // {strategy:null, base_branches:[]}' <<<"$profile_json")
fi

# --- hook presence (signal only, not exhaustive) ----------------------------

husky_present=false
precommit_present=false
core_hooks_present=false

[[ -f "$target/.husky/pre-commit" || -f "$target/.husky/commit-msg" ]] && husky_present=true
[[ -f "$target/.pre-commit-config.yaml" ]] && precommit_present=true
if [[ -f "$target/.git/hooks/pre-commit" ]] && grep -q 'nyann-managed-hook' "$target/.git/hooks/pre-commit" 2>/dev/null; then
  core_hooks_present=true
fi

hooks_block=$(jq -n \
  --argjson husky "$husky_present" \
  --argjson pc "$precommit_present" \
  --argjson core "$core_hooks_present" \
  '{husky:$husky, pre_commit_com:$pc, core:$core}')

# --- CLAUDE.md --------------------------------------------------------------

claudemd_block='{"present": false, "bytes": 0, "router_markers": false}'
cm="$target/CLAUDE.md"
if [[ -f "$cm" ]]; then
  bytes=$(wc -c < "$cm" | tr -d ' ')
  markers=false
  grep -q 'nyann:start' "$cm" 2>/dev/null && markers=true
  claudemd_block=$(jq -n --argjson bytes "$bytes" --argjson markers "$markers" \
    '{present:true, bytes:$bytes, router_markers:$markers}')
fi

# --- assemble ---------------------------------------------------------------

out_json=$(jq -n \
  --arg repo "$target" \
  --arg branch "$branch" \
  --argjson stack "$stack_block" \
  --argjson profile "$profile_block" \
  --argjson branching "$branching_block" \
  --argjson hooks "$hooks_block" \
  --argjson claude_md "$claudemd_block" \
  --argjson recent "$recent_json" \
  '{
    repo:$repo,
    branch:$branch,
    stack:$stack,
    profile:$profile,
    branching:$branching,
    hooks:$hooks,
    claude_md:$claude_md,
    recent_commits:$recent
  }')

if $json_out; then
  echo "$out_json"
  exit 0
fi

# --- human-readable render --------------------------------------------------

render_kv() {
  # $1 label, $2 value
  printf '  %-22s %s\n' "$1" "${2:-—}"
}

printf 'nyann state — %s\n' "$target"
printf '\nBranch:\n'
render_kv "current" "$branch"
render_kv "recent commits" "$(jq -r '.recent_commits | length | "\(.)"' <<<"$out_json")"

printf '\nStack:\n'
render_kv "primary_language" "$(jq -r '.stack.primary_language // "unknown"' <<<"$out_json")"
render_kv "framework"        "$(jq -r '.stack.framework // "—"' <<<"$out_json")"
render_kv "package_manager"  "$(jq -r '.stack.package_manager // "—"' <<<"$out_json")"

printf '\nProfile:\n'
render_kv "name"   "$(jq -r '.profile.name // "(unknown)"' <<<"$out_json")"
render_kv "source" "$(jq -r '.profile.source // "unknown"' <<<"$out_json")"

printf '\nBranching:\n'
render_kv "strategy"      "$(jq -r '.branching.strategy // "—"' <<<"$out_json")"
render_kv "base_branches" "$(jq -r '.branching.base_branches // [] | join(", ")' <<<"$out_json")"

printf '\nHooks:\n'
render_kv "husky"          "$(jq -r '.hooks.husky' <<<"$out_json")"
render_kv "pre-commit.com" "$(jq -r '.hooks.pre_commit_com' <<<"$out_json")"
render_kv "nyann core"     "$(jq -r '.hooks.core' <<<"$out_json")"

printf '\nCLAUDE.md:\n'
render_kv "present"        "$(jq -r '.claude_md.present' <<<"$out_json")"
render_kv "bytes"          "$(jq -r '.claude_md.bytes' <<<"$out_json")"
render_kv "router markers" "$(jq -r '.claude_md.router_markers' <<<"$out_json")"
