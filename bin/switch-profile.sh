#!/usr/bin/env bash
# switch-profile.sh — compute a migration plan between two profiles.
#
# Usage:
#   switch-profile.sh --from <name> --to <name> --target <repo>
#                     [--dry-run] [--json] [--yes]
#
# Loads both profiles, computes the diff (hooks added/removed, branching
# strategy change, extras toggled, conventions changed), and emits a
# structured MigrationPlan.
#
# Modes:
#   --dry-run    print the plan and exit 0 without invoking bootstrap.
#   --yes        explicit confirmation that a human has seen the plan.
#                Required to actually apply (invoke bootstrap).
#   (default)    print the plan and exit 0 with a "preview" hint —
#                same as --dry-run with a recommendation to re-run
#                with --yes once a human has reviewed.
#
# The migrate-profile skill is responsible for showing the plan to
# the user and prompting for confirmation; once it has consent it
# re-invokes with --yes. Direct shell callers (CI helpers, scripts)
# get the same protection: no preview/confirm = no mutation.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

from_name=""
to_name=""
target=""
dry_run=false
json_output=false
yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)       from_name="${2:-}"; shift 2 ;;
    --from=*)     from_name="${1#--from=}"; shift ;;
    --to)         to_name="${2:-}"; shift 2 ;;
    --to=*)       to_name="${1#--to=}"; shift ;;
    --target)     target="${2:-}"; shift 2 ;;
    --target=*)   target="${1#--target=}"; shift ;;
    --dry-run)    dry_run=true; shift ;;
    --json)       json_output=true; shift ;;
    --yes)        yes=true; shift ;;
    -h|--help)    sed -n '3,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$from_name" ]] || nyann::die "--from <profile-name> is required"
[[ -n "$to_name" ]]   || nyann::die "--to <profile-name> is required"
[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
target="$(cd "$target" && pwd)"

# --- Load both profiles via load-profile.sh ---------------------------------

# load-profile.sh emits profile JSON to stdout, logs source to stderr.
# We need the JSON content, not the file path.
from_json=$("${_script_dir}/load-profile.sh" "$from_name" 2>/dev/null) \
  || nyann::die "cannot resolve source profile: $from_name"
to_json=$("${_script_dir}/load-profile.sh" "$to_name" 2>/dev/null) \
  || nyann::die "cannot resolve target profile: $to_name"

# --- Compute diff -----------------------------------------------------------

additions='[]'
removals='[]'
changes='[]'

add_entry() {
  local list_var="$1" category="$2" path="$3" before="$4" after="$5" action="$6"
  local entry
  entry=$(jq -n \
    --arg cat "$category" \
    --arg path "$path" \
    --arg before "$before" \
    --arg after "$after" \
    --arg action "$action" \
    '{ category: $cat, path: $path, before: $before, after: $after, action: $action }')
  local current
  case "$list_var" in
    additions) current="$additions" ;;
    removals)  current="$removals" ;;
    changes)   current="$changes" ;;
    *) nyann::die "add_entry: unknown list: $list_var" ;;
  esac
  local updated
  updated=$(jq --argjson e "$entry" '. + [$e]' <<<"$current")
  case "$list_var" in
    additions) additions="$updated" ;;
    removals)  removals="$updated" ;;
    changes)   changes="$updated" ;;
  esac
}

# Hook diffs
for phase in pre_commit commit_msg pre_push; do
  from_hooks=$(jq -r ".hooks.${phase} // [] | .[]" <<<"$from_json" | sort)
  to_hooks=$(jq -r ".hooks.${phase} // [] | .[]" <<<"$to_json" | sort)

  # Added hooks
  while IFS= read -r hook; do
    [[ -z "$hook" ]] && continue
    if ! echo "$from_hooks" | grep -Fxq "$hook"; then
      add_entry additions "hook" "hooks.${phase}.${hook}" "" "$hook" "add"
    fi
  done <<<"$to_hooks"

  # Removed hooks
  while IFS= read -r hook; do
    [[ -z "$hook" ]] && continue
    if ! echo "$to_hooks" | grep -Fxq "$hook"; then
      add_entry removals "hook" "hooks.${phase}.${hook}" "$hook" "" "remove"
    fi
  done <<<"$from_hooks"
done

# Branching strategy
from_strategy=$(jq -r '.branching.strategy' <<<"$from_json")
to_strategy=$(jq -r '.branching.strategy' <<<"$to_json")
if [[ "$from_strategy" != "$to_strategy" ]]; then
  add_entry changes "branching" "branching.strategy" "$from_strategy" "$to_strategy" "change"
fi

# Extras diffs
for extra in gitignore editorconfig claude_md github_actions_ci github_templates commit_message_template; do
  from_val=$(jq -r ".extras.${extra} // false" <<<"$from_json")
  to_val=$(jq -r ".extras.${extra} // false" <<<"$to_json")
  if [[ "$from_val" != "$to_val" ]]; then
    add_entry changes "extras" "extras.${extra}" "$from_val" "$to_val" "change"
  fi
done

# Conventions
from_format=$(jq -r '.conventions.commit_format' <<<"$from_json")
to_format=$(jq -r '.conventions.commit_format' <<<"$to_json")
if [[ "$from_format" != "$to_format" ]]; then
  add_entry changes "conventions" "conventions.commit_format" "$from_format" "$to_format" "change"
fi

# CI changes
from_ci=$(jq -r '.ci.enabled // false' <<<"$from_json")
to_ci=$(jq -r '.ci.enabled // false' <<<"$to_json")
if [[ "$from_ci" != "$to_ci" ]]; then
  add_entry changes "ci" "ci.enabled" "$from_ci" "$to_ci" "change"
fi

# --- Output MigrationPlan ---------------------------------------------------

plan=$(jq -n \
  --arg from "$from_name" \
  --arg to "$to_name" \
  --argjson additions "$additions" \
  --argjson removals "$removals" \
  --argjson changes "$changes" \
  '{
    from_profile: $from,
    to_profile: $to,
    additions: $additions,
    removals: $removals,
    changes: $changes,
    total_modifications: (($additions | length) + ($removals | length) + ($changes | length))
  }')

if [[ "$json_output" == "true" || "$dry_run" == "true" ]]; then
  printf '%s\n' "$plan"
  exit 0
fi

# Preview-before-mutate guard. Without --yes the caller hasn't shown
# the plan to a human and gotten an explicit go-ahead, so emit the
# plan and exit 0 — the migrate-profile skill (or any direct caller)
# is responsible for showing it, prompting, and re-invoking with
# --yes once consent is in hand. Trusting the skill layer to prompt
# without enforcing it at the script gives any other caller (CI
# helpers, ad-hoc scripts) a silent path past the consent gate.
if ! $yes; then
  printf '%s\n' "$plan"
  nyann::warn "preview only: re-run with --yes to apply (or --dry-run to confirm intent)"
  exit 0
fi

# --- Apply migration (non-dry-run) ------------------------------------------

total=$(jq -r '.total_modifications' <<<"$plan")
if [[ "$total" -eq 0 ]]; then
  nyann::log "profiles are identical — nothing to migrate"
  exit 0
fi

nyann::log "migrating $from_name → $to_name ($total modification(s))"

# Re-bootstrap with the new profile
_switch_cleanup() {
  rm -f "${stack_tmp:-}" "${to_profile_tmp:-}" "${doc_plan_tmp:-}" "${plan_tmp:-}" "${bootstrap_err:-}"
}
trap _switch_cleanup EXIT

stack_path=""
if [[ -f "$target/.stack.json" ]]; then
  stack_path="$target/.stack.json"
else
  stack_tmp=$(mktemp -t nyann-stack.XXXXXX)
  "${_script_dir}/detect-stack.sh" --path "$target" > "$stack_tmp" 2>/dev/null || true
  stack_path="$stack_tmp"
fi

to_profile_tmp=$(mktemp -t nyann-to-profile.XXXXXX)
printf '%s\n' "$to_json" > "$to_profile_tmp"

doc_plan_tmp=$(mktemp -t nyann-docplan.XXXXXX)
"${_script_dir}/route-docs.sh" --profile "$to_profile_tmp" > "$doc_plan_tmp" 2>/dev/null || true

# Build a plan that re-generates only what the new profile actually opts
# into. Earlier this hardcoded `[CLAUDE.md, ci.yml, PR template]`, which
# (a) silently bypassed preview-before-mutate when the new profile
# disables those extras and (b) lied to the user about what was about
# to be written. Derive each entry from the new profile's extras +
# ci.enabled, and append every local-type target the doc plan declares.
# bootstrap.sh refuses to materialise a file that isn't in writes[], so
# omitting an entry here = that file won't be (re)written. That's the
# whole point — switching to a profile that disables CI shouldn't
# regenerate ci.yml.
plan_tmp=$(mktemp -t nyann-plan.XXXXXX)
plan_writes='[]'

want_editorconfig=$(jq -r '.extras.editorconfig // false'              <<<"$to_json")
want_claude_md=$(jq -r   '.extras.claude_md // false'                  <<<"$to_json")
want_ci=$(jq -r          '.ci.enabled // false'                        <<<"$to_json")
want_pr_template=$(jq -r '.extras.github_templates // false'           <<<"$to_json")
want_gitignore=$(jq -r   '.extras.gitignore // false'                  <<<"$to_json")
want_gitmsg=$(jq -r      '.extras.commit_message_template // false'    <<<"$to_json")

append_write() {
  local path="$1"
  plan_writes=$(jq --arg p "$path" \
    '. + [{path:$p, action:"overwrite", bytes:0}]' \
    <<<"$plan_writes")
}

[[ "$want_gitignore"    == "true" ]] && append_write ".gitignore"
[[ "$want_editorconfig" == "true" ]] && append_write ".editorconfig"
[[ "$want_gitmsg"       == "true" ]] && append_write ".gitmessage"
[[ "$want_claude_md"    == "true" ]] && append_write "CLAUDE.md"
[[ "$want_ci"           == "true" ]] && append_write ".github/workflows/ci.yml"
[[ "$want_pr_template"  == "true" ]] && append_write ".github/PULL_REQUEST_TEMPLATE.md"

# Walk the doc plan: every local-type target contributes its path to
# writes[] so scaffold-docs sees its outputs reflected in the preview.
if [[ -s "$doc_plan_tmp" ]]; then
  while IFS= read -r doc_path; do
    [[ -n "$doc_path" && "$doc_path" != "null" ]] || continue
    append_write "$doc_path"
  done < <(jq -r '
    .targets // {}
    | to_entries
    | map(select(.value.type == "local" and (.value.path // "") != ""))
    | .[].value.path
  ' "$doc_plan_tmp")
fi

jq -n --argjson writes "$plan_writes" \
  '{ writes: $writes, commands: [], remote: [] }' > "$plan_tmp"

# Render the plan through preview.sh and capture its canonical SHA-256.
# Passing --plan-sha256 to bootstrap binds the bytes the user just saw
# rendered to the bytes bootstrap will execute, closing the same TOCTOU
# window that direct skill→preview→bootstrap flows close. The
# migrate-profile skill is responsible for the user-confirmation half
# of preview-before-mutate (it prompts "Apply this migration?" before
# invoking switch-profile without --dry-run); the SHA-binding here
# covers the integrity half.
plan_sha=$("${_script_dir}/preview.sh" --plan "$plan_tmp" --emit-sha256 2>/dev/null) \
  || nyann::die "preview/sha256 generation failed for migration plan"

bootstrap_err=$(mktemp -t nyann-bserr.XXXXXX)
if ! "${_script_dir}/bootstrap.sh" \
  --target "$target" \
  --plan "$plan_tmp" \
  --plan-sha256 "$plan_sha" \
  --profile "$to_profile_tmp" \
  --doc-plan "$doc_plan_tmp" \
  --stack "$stack_path" > /dev/null 2>"$bootstrap_err"; then
  nyann::warn "bootstrap during migration encountered errors:"
  cat "$bootstrap_err" >&2
fi

nyann::log "migration complete: now using profile '$to_name'"
printf '%s\n' "$plan"
