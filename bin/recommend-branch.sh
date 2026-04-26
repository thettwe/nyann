#!/usr/bin/env bash
# recommend-branch.sh — pick a branching strategy from a StackDescriptor.
#
# Usage: recommend-branch.sh < StackDescriptor.json
#        or recommend-branch.sh --stack /path/to/descriptor.json
#
# Emits a BranchingChoice JSON to stdout (schemas/branching-choice.schema.json).
# Implements a weighted heuristic:
#   has_changelog && has_semver_tags                → GitFlow  +0.5
#   is_monorepo || contributor_count > 5            → Trunk    +0.4
#   empty repo / solo dev / no release signals      → GHF      +0.6 (default)
#   framework=next / prototype-ish stack            → GHF      +0.2
# The max-scoring strategy wins. Ties or a winning score < 0.65 set
# needs_user_confirm=true so the skill layer asks before acting.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# --- arg parsing --------------------------------------------------------------

stack_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)     stack_path="${2:-}"; shift 2 ;;
    --stack=*)   stack_path="${1#--stack=}"; shift ;;
    -h|--help)
      sed -n '3,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- load descriptor ----------------------------------------------------------

if [[ -n "$stack_path" ]]; then
  [[ -f "$stack_path" ]] || nyann::die "stack file not found: $stack_path"
  stack_json="$(<"$stack_path")"
else
  if [[ -t 0 ]]; then
    nyann::die "no StackDescriptor provided; pipe one in or pass --stack <file>"
  fi
  stack_json="$(cat)"
fi

# Guard against garbage input early.
jq -e 'type == "object" and has("primary_language")' <<<"$stack_json" >/dev/null \
  || nyann::die "input is not a valid StackDescriptor"

# --- pull signals -------------------------------------------------------------

has_changelog=$(jq -r '.has_changelog' <<<"$stack_json")
has_semver_tags=$(jq -r '.has_semver_tags' <<<"$stack_json")
is_monorepo=$(jq -r '.is_monorepo' <<<"$stack_json")
contributor_count=$(jq -r '.contributor_count' <<<"$stack_json")
framework=$(jq -r '.framework // ""' <<<"$stack_json")

# --- score strategies ---------------------------------------------------------

# Strategy base weights.
s_ghf=0.0
s_gitflow=0.0
s_trunk=0.0

reasoning_json='[]'
add_reason() { reasoning_json="$(jq --arg r "$1" '. + [$r]' <<<"$reasoning_json")"; }

# GitFlow: library-style cadence.
if [[ "$has_changelog" == "true" && "$has_semver_tags" == "true" ]]; then
  s_gitflow=$(awk -v base="$s_gitflow" 'BEGIN{print base + 0.5}')
  add_reason "CHANGELOG.md + semver tags present → +0.5 for GitFlow (library-style release cadence)"
fi

# Trunk-based: monorepo or large-team signals.
if [[ "$is_monorepo" == "true" ]]; then
  s_trunk=$(awk -v base="$s_trunk" 'BEGIN{print base + 0.4}')
  add_reason "Monorepo detected → +0.4 for Trunk-based"
fi
if [[ "$contributor_count" =~ ^[0-9]+$ ]] && (( contributor_count > 5 )); then
  s_trunk=$(awk -v base="$s_trunk" 'BEGIN{print base + 0.4}')
  add_reason "contributor_count=$contributor_count (>5) → +0.4 for Trunk-based"
fi

# GitHub Flow: the +0.6 fires only when the repo looks like app/prototype work
# with no strong GitFlow or Trunk signals. "Empty repo / solo dev / no
# release signals" are the qualifiers, not an always-on default.
ghf_qualifies=false
if [[ "$has_changelog" != "true" || "$has_semver_tags" != "true" ]]; then
  if [[ "$is_monorepo" != "true" ]] && ! { [[ "$contributor_count" =~ ^[0-9]+$ ]] && (( contributor_count > 5 )); }; then
    ghf_qualifies=true
  fi
fi

if $ghf_qualifies; then
  s_ghf=$(awk "BEGIN{print $s_ghf + 0.6}")
  add_reason "No GitFlow/Trunk signals (app/prototype shape) → +0.6 for GitHub Flow"
fi

case "$framework" in
  next|nuxt|remix|sveltekit|react|vue)
    s_ghf=$(awk "BEGIN{print $s_ghf + 0.2}")
    add_reason "Frontend app framework ($framework) → +0.2 for GitHub Flow"
    ;;
esac

# Small tie-break nudge so GHF still beats a literal zero when no strategy
# scored. Applies universally so the fallback is deterministic.
s_ghf=$(awk "BEGIN{print $s_ghf + 0.05}")

# --- pick winner --------------------------------------------------------------

winner="github-flow"
winner_score=$s_ghf
# Strict inequality for picking; ties flagged downstream.
if awk "BEGIN{exit !($s_gitflow > $winner_score)}"; then
  winner="gitflow"; winner_score=$s_gitflow
fi
if awk "BEGIN{exit !($s_trunk > $winner_score)}"; then
  winner="trunk-based"; winner_score=$s_trunk
fi

# Detect ties with other strategies — any strategy within 0.01 of winner.
tie=false
for cand in "github-flow:$s_ghf" "gitflow:$s_gitflow" "trunk-based:$s_trunk"; do
  name="${cand%:*}"; score="${cand#*:}"
  [[ "$name" == "$winner" ]] && continue
  if awk "BEGIN{exit !(($winner_score - $score) < 0.01 && ($winner_score - $score) > -0.01 && $score > 0)}"; then
    tie=true
  fi
done

# Cap confidence at 1.0.
confidence=$(awk -v s="$winner_score" 'BEGIN{ if (s > 1.0) s = 1.0; printf "%.2f", s; }')

needs_user_confirm=false
if $tie; then
  needs_user_confirm=true
  add_reason "Multiple strategies scored close to the winner → needs_user_confirm = true"
fi
if awk "BEGIN{exit !($winner_score < 0.65)}"; then
  needs_user_confirm=true
  add_reason "Winning score ${confidence} < 0.65 threshold → needs_user_confirm = true"
fi

# --- branch_name_patterns + base branches per strategy ------------------------

case "$winner" in
  github-flow)
    base_branches='["main"]'
    long_lived='[]'
    default_base='"main"'
    patterns='{
      "feature": "feat/{slug}",
      "bugfix":  "fix/{slug}"
    }'
    ;;
  gitflow)
    base_branches='["main"]'
    long_lived='["develop"]'
    default_base='"develop"'
    patterns='{
      "feature": "feat/{slug}",
      "bugfix":  "fix/{slug}",
      "release": "release/{version}",
      "hotfix":  "hotfix/{slug}"
    }'
    ;;
  trunk-based)
    base_branches='["main"]'
    long_lived='[]'
    default_base='"main"'
    patterns='{
      "feature": "feat/{slug}",
      "bugfix":  "fix/{slug}"
    }'
    ;;
esac

# --- emit ---------------------------------------------------------------------

jq -n \
  --arg recommendation "$winner" \
  --argjson confidence "$confidence" \
  --argjson reasoning "$reasoning_json" \
  --argjson base_branches "$base_branches" \
  --argjson long_lived_branches "$long_lived" \
  --argjson branch_name_patterns "$patterns" \
  --argjson default_base "$default_base" \
  --argjson needs_user_confirm "$needs_user_confirm" \
  '{
    recommendation: $recommendation,
    confidence: $confidence,
    reasoning: $reasoning,
    base_branches: $base_branches,
    long_lived_branches: $long_lived_branches,
    branch_name_patterns: $branch_name_patterns,
    default_base: $default_base,
    needs_user_confirm: $needs_user_confirm
  }'
