#!/usr/bin/env bash
# Guard: iac-policy — evaluate OPA/Conftest policies against IaC changes.
#
# OPT-IN. Off by default: NOT in any flow's builtin_guards list — it runs
# only when a profile names it in `guards.pr` / `guards.release` /
# `guards.ship`. Advisory by default; profile-promotable via the
# guards.<flow>[].severity lever. Skips silently when `conftest` is not
# installed or the policy dir has no .rego files — policy tooling must
# never block people who haven't adopted it.
#
# Two modes, dispatched by whether $1 starts with `--` (the coverage-delta
# pattern):
#
#   Guard mode (positional, invoked by pre-action-guard.sh):
#       iac-policy.sh <target> <base> [<profile.json>]
#     FILESYSTEM-ONLY by design: conftest runs over the IaC files changed
#     vs <base> (all tracked IaC files when <base> is unresolvable). A
#     pre-action guard must NEVER silently run a cloud CLI — `terraform
#     plan` needs backend + credentials and can take minutes, which is
#     not something a commit/PR flow may spring on the user.
#
#   Plan mode (explicit, invoked by the iac-plan / iac-apply skills):
#       iac-policy.sh --plan-file <iac-plan.json> --target <dir> [--profile <p>]
#     Pipes the normalized IacPlan JSON to `conftest test -` so policies
#     can gate on `input.summary.add/change/destroy`, `input.tool`, etc.
#     Used AFTER the operator explicitly ran a plan — the cloud CLI ran
#     because they asked, not because a guard fired.
#
# Policy dir: profile `guards.iac_policy_dir` (default `.nyann/policies`),
# resolved relative to the target. Seed policies + the input contract for
# both modes live in <plugin_root>/templates/policies/.
#
# Output: ONE GuardResult fragment on stdout; ALWAYS exit 0 (exit codes
# 3/4 are pre-action-guard's job).

_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

emit() { # pass skipped message
  jq -n --argjson pass "$1" --argjson skipped "$2" --arg msg "$3" \
    '{name:"iac-policy", pass:$pass, severity:"advisory", message:$msg}
     + (if $skipped then {skipped:true} else {} end)'
}

command -v jq >/dev/null 2>&1 || {
  echo '{"name":"iac-policy","pass":true,"severity":"advisory","skipped":true,"message":"jq unavailable — skipped"}'
  exit 0
}

# --- arg parsing (two modes) --------------------------------------------------

plan_file=""
target="$PWD"
base="main"
profile=""
if [[ "${1-}" == --* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan-file)   plan_file="${2-}"; shift 2 ;;
      --plan-file=*) plan_file="${1#--plan-file=}"; shift ;;
      --target)      target="${2-}"; shift 2 ;;
      --target=*)    target="${1#--target=}"; shift ;;
      --profile)     profile="${2-}"; shift 2 ;;
      --profile=*)   profile="${1#--profile=}"; shift ;;
      *) shift ;;
    esac
  done
else
  target="${1-$PWD}"
  base="${2:-main}"
  profile="${3-}"
fi

# --- resolve policies + conftest ---------------------------------------------

policy_rel=".nyann/policies"
if [[ -n "$profile" && -f "$profile" ]]; then
  p=$(jq -r '.guards.iac_policy_dir // empty' "$profile" 2>/dev/null || true)
  [[ -n "$p" ]] && policy_rel="$p"
fi
policy_dir="$target/$policy_rel"

if ! command -v conftest >/dev/null 2>&1; then
  emit true true "conftest not installed — skipped"
  exit 0
fi
if ! compgen -G "$policy_dir/*.rego" >/dev/null 2>&1; then
  emit true true "no policies under $policy_rel — skipped"
  exit 0
fi

# run_conftest <mode-label> <conftest-arg...> — shared result rendering.
run_conftest() {
  local label="$1"; shift
  local out failures warnings first
  out=$(conftest test --policy "$policy_dir" --output json "$@" 2>/dev/null) || true
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
    emit true true "conftest produced no parseable result ($label) — skipped"
    return 0
  fi
  failures=$(jq '[.[].failures // [] | length] | add // 0' <<<"$out")
  warnings=$(jq '[.[].warnings // [] | length] | add // 0' <<<"$out")
  if (( failures > 0 )); then
    first=$(jq -r '[.[].failures // [] | .[].msg][0:2] | join("; ")' <<<"$out")
    emit false false "$failures policy violation(s) [$label] — $first"
  elif (( warnings > 0 )); then
    emit true false "policies passed with $warnings warning(s) [$label]"
  else
    emit true false "policies passed [$label]"
  fi
}

# --- plan mode ---------------------------------------------------------------

if [[ -n "$plan_file" ]]; then
  if [[ ! -f "$plan_file" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 "$plan_file"; then
    emit true true "plan file unreadable — skipped"
    exit 0
  fi
  # `-` = read the document from stdin; the redirect on the function call
  # hands the plan JSON straight to conftest inside run_conftest.
  run_conftest "plan" - < "$plan_file"
  exit 0
fi

# --- guard (file) mode -------------------------------------------------------
# Changed IaC files vs base; all tracked IaC files when base is missing.
# CI/workflow YAML is excluded (it's pipeline config, not infrastructure).

files=()
if git -C "$target" rev-parse --verify "$base" >/dev/null 2>&1; then
  while IFS= read -r f; do
    [[ -n "$f" && -f "$target/$f" ]] && files+=("$target/$f")
  done < <(git -C "$target" diff --name-only --diff-filter=d "${base}...HEAD" 2>/dev/null \
    | grep -E '\.(tf|tfvars|ya?ml)$' | grep -v '^\.github/' || true)
else
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$target/$f")
  done < <(git -C "$target" ls-files -- '*.tf' '*.tfvars' '*.yaml' '*.yml' 2>/dev/null \
    | grep -v '^\.github/' || true)
fi

if (( ${#files[@]} == 0 )); then
  emit true true "no IaC file changes to evaluate — skipped"
  exit 0
fi

run_conftest "files" "${files[@]}"
exit 0
