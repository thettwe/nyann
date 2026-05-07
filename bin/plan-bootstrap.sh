#!/usr/bin/env bash
# plan-bootstrap.sh — compose an ActionPlan from a profile + stack + doc-plan.
#
# Usage:
#   plan-bootstrap.sh --target <repo> --profile <path> --doc-plan <path>
#                     --stack <path> [--branching <strategy>]
#
# Output: ActionPlan JSON on stdout (schemas/action-plan.schema.json).
#
# Extracted from skills/bootstrap-project/SKILL.md so simulation
# (bin/setup.sh --simulate) can preview a bootstrap without going
# through the skill layer's interactive prompts. The bootstrap skill
# itself can also call this — keeping plan composition out of natural-
# language space removes a class of "skill drifted from bin" bugs.
#
# v1.7.0 scope: non-monorepo repos. When `stack.is_monorepo == true`
# the plan emits `{simulation: "partial", reason: "monorepo"}` to
# stderr and a still-valid ActionPlan that omits per-workspace entries.
# The skill layer continues to handle monorepo-specific writes
# (workspace configs, per-workspace lint-staged) inline.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
doc_plan_path=""
stack_path=""
# branching is accepted for future use (recommend-branch hand-off);
# v1.7.0 plan-bootstrap doesn't write base branches — that's still
# bootstrap.sh's job after `git init`.
branching=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --profile)       profile_path="${2:-}"; shift 2 ;;
    --profile=*)     profile_path="${1#--profile=}"; shift ;;
    --doc-plan)      doc_plan_path="${2:-}"; shift 2 ;;
    --doc-plan=*)    doc_plan_path="${1#--doc-plan=}"; shift ;;
    --stack)         stack_path="${2:-}"; shift 2 ;;
    --stack=*)       stack_path="${1#--stack=}"; shift ;;
    --branching)     branching="${2:-}"; shift 2 ;;
    --branching=*)   branching="${1#--branching=}"; shift ;;
    -h|--help)       sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
[[ -n "$doc_plan_path" && -f "$doc_plan_path" ]] || nyann::die "--doc-plan <path> is required"
[[ -n "$stack_path" && -f "$stack_path" ]] || nyann::die "--stack <path> is required"

target="$(cd "$target" && pwd)"
profile_json=$(cat "$profile_path")
doc_plan_json=$(cat "$doc_plan_path")
stack_json=$(cat "$stack_path")

# Note + still emit a usable plan when the repo is a monorepo. The
# skill caller is the one that knows how to add per-workspace writes;
# this script only composes the universal entries.
is_monorepo=$(jq -r '.is_monorepo // false' <<<"$stack_json")
if [[ "$is_monorepo" == "true" ]]; then
  nyann::warn "stack reports is_monorepo=true; per-workspace writes are NOT included in this plan. The skill layer should append them."
fi

# --- writes[] ----------------------------------------------------------------
# Build the writes array as a JSON list of objects. Each entry mirrors
# what bootstrap-project/SKILL.md step 5 documents as required.

writes='[]'

# Helper: append a write entry. Action defaults to "create"; pass "merge"
# (as $2) when the file already exists at $target/$path so preview can
# render a diff via render-plan.sh.
add_write() {
  local path="$1" action_hint="${2-}"
  local action="create"
  local bytes_field=""
  if [[ -e "$target/$path" ]]; then
    action="merge"
  fi
  # If the caller hinted "merge" explicitly (e.g. for files we always
  # merge regardless of existence — like CLAUDE.md when the file
  # exists with markers), respect the override.
  [[ -n "$action_hint" ]] && action="$action_hint"
  if [[ -f "$target/$path" ]]; then
    bytes_field=$(wc -c < "$target/$path" | tr -d ' ')
  fi
  if [[ -n "$bytes_field" ]]; then
    writes=$(jq --arg p "$path" --arg a "$action" --argjson b "$bytes_field" \
      '. + [{ path: $p, action: $a, bytes: $b }]' <<<"$writes")
  else
    writes=$(jq --arg p "$path" --arg a "$action" \
      '. + [{ path: $p, action: $a, bytes: 0 }]' <<<"$writes")
  fi
}

# .gitignore — every profile that opts into extras.gitignore
if [[ "$(jq -r '.extras.gitignore // false' <<<"$profile_json")" == "true" ]]; then
  add_write ".gitignore"
fi

# .editorconfig
if [[ "$(jq -r '.extras.editorconfig // false' <<<"$profile_json")" == "true" ]]; then
  add_write ".editorconfig"
fi

# CLAUDE.md — when extras.claude_md=true
if [[ "$(jq -r '.extras.claude_md // false' <<<"$profile_json")" == "true" ]]; then
  add_write "CLAUDE.md"
fi

# Hook files: derive from the profile.hooks lists, mirroring the same
# logic compute-drift uses to detect "missing".
hook_list=$(jq -r '[(.hooks.pre_commit // [])[], (.hooks.commit_msg // [])[]] | join(" ")' <<<"$profile_json")
case "$hook_list" in
  *eslint*|*prettier*|*commitlint*)
    add_write ".husky/pre-commit"
    add_write ".husky/commit-msg"
    add_write "commitlint.config.js"
    ;;
esac
case "$hook_list" in
  *ruff*|*commitizen*|*black*|*mypy*)
    add_write ".pre-commit-config.yaml"
    ;;
esac

# Core hooks (commit-msg validator + block-main + gitleaks). These
# always land — the install-hooks installer handles the framework
# choice (husky vs pre-commit vs core .git/hooks).
add_write ".git/hooks/commit-msg" "create"
add_write ".git/hooks/pre-commit" "create"

# CI workflow
if [[ "$(jq -r '.ci.enabled // false' <<<"$profile_json")" == "true" ]]; then
  add_write ".github/workflows/ci.yml"
fi

# GitHub templates
if [[ "$(jq -r '.extras.github_templates // false' <<<"$profile_json")" == "true" ]]; then
  add_write ".github/PULL_REQUEST_TEMPLATE.md"
fi

# Doc scaffolds — read from the DocumentationPlan, not the profile,
# because route-docs is the source of truth for which doc types apply.
# DocumentationPlan.targets is an object keyed by doc type ({adrs:
# {type, path}, …}); only entries with type=="local" map to writes
# (MCP-routed targets get materialised by the skill via MCP calls,
# not via the local writes[] queue).
while IFS=$'\t' read -r dtype dpath; do
  [[ -z "$dpath" || "$dpath" == "null" ]] && continue
  case "$dtype" in
    research)
      add_write "${dpath%/}/README.md"
      ;;
    adrs)
      add_write "${dpath%/}/ADR-000-record-architecture-decisions.md"
      ;;
    memory)
      # memory/README.md is always local — the memory-is-always-local
      # invariant guarantees this regardless of routing choice.
      add_write "${dpath%/}/README.md"
      ;;
    *)
      add_write "$dpath"
      ;;
  esac
done < <(
  jq -r '
    (.targets // {})
    | to_entries[]
    | select(.value.type == "local")
    | [.key, (.value.path // "")]
    | @tsv
  ' <<<"$doc_plan_json"
)

# --- commands[] --------------------------------------------------------------
# bootstrap.sh runs git init when the target lacks .git; otherwise no
# top-level commands. Workspace-specific install commands belong in the
# skill layer's monorepo path, not here.
commands='[]'
if [[ ! -d "$target/.git" ]]; then
  commands=$(jq -nc '[{ cmd: "git init", cwd: "." }]')
fi

# Reference $branching so shellcheck doesn't flag it; future revisions
# will consume the resolved strategy from `recommend-branch.sh`. The
# variable is intentionally accepted but currently informational only.
: "${branching:-}"

# --- remote[] ----------------------------------------------------------------
# bootstrap.sh's remote[] is reserved for branch-protection apply etc.
# The plan-builder doesn't compose them — gh-integration.sh runs after
# bootstrap success. Always empty here.
remote='[]'

# --- emit --------------------------------------------------------------------
jq -n \
  --argjson writes "$writes" \
  --argjson commands "$commands" \
  --argjson remote "$remote" \
  '{ writes: $writes, commands: $commands, remote: $remote }'
