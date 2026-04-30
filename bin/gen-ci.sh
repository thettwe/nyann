#!/usr/bin/env bash
# gen-ci.sh — generate a GitHub Actions CI workflow from the profile's stack.
#
# Usage:
#   gen-ci.sh --profile <path> --stack <path> --target <repo> [--dry-run]
#             [--governance]                 # also generate governance-check.yml
#             [--allow-merge-existing]       # append to existing workflow files
#
# Selects a CI template based on primary_language, substitutes package
# manager / versions / commands from stack + profile, and writes
# .github/workflows/ci.yml. Regenerates between marker comments only;
# preserves user content outside the markers.
#
# --governance also generates .github/workflows/governance-check.yml
# from templates/ci/governance-check.yml (drift + health-score gate).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
stack_path=""
dry_run=false
allow_merge=false
governance=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)               target="${2:-}"; shift 2 ;;
    --target=*)             target="${1#--target=}"; shift ;;
    --profile)              profile_path="${2:-}"; shift 2 ;;
    --profile=*)            profile_path="${1#--profile=}"; shift ;;
    --stack)                stack_path="${2:-}"; shift 2 ;;
    --stack=*)              stack_path="${1#--stack=}"; shift ;;
    --dry-run)              dry_run=true; shift ;;
    --allow-merge-existing) allow_merge=true; shift ;;
    --governance)           governance=true; shift ;;
    -h|--help)              sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
[[ -n "$stack_path" && -f "$stack_path" ]] || nyann::die "--stack <path> is required"
target="$(cd "$target" && pwd)"

profile_json="$(cat "$profile_path")"
stack_json="$(cat "$stack_path")"

# --- Resolve template based on primary language --------------------------------

lang=$(jq -r '.primary_language // "unknown"' <<<"$stack_json")
templates_dir="${_script_dir}/../templates/ci"

case "$lang" in
  typescript|javascript) template_file="${templates_dir}/typescript.yml" ;;
  python)                template_file="${templates_dir}/python.yml" ;;
  go)                    template_file="${templates_dir}/go.yml" ;;
  rust)                  template_file="${templates_dir}/rust.yml" ;;
  *)                     template_file="${templates_dir}/generic.yml" ;;
esac

[[ -f "$template_file" ]] || nyann::die "CI template not found: $template_file"

# --- Resolve substitution variables -------------------------------------------

base_branches=$(jq -r '.branching.base_branches | join(", ")' <<<"$profile_json")
pkg_mgr=$(jq -r '.stack.package_manager // "npm"' <<<"$profile_json")

# CI section from profile (optional)
ci_json=$(jq -r '.ci // {}' <<<"$profile_json")
node_version=$(jq -r '.node_version // "20"' <<<"$ci_json")
python_version=$(jq -r '.python_version // "3.12"' <<<"$ci_json")
go_version=$(jq -r '.go_version // "1.22"' <<<"$ci_json")

# Package manager specific commands
case "$pkg_mgr" in
  pnpm)  install_cmd="pnpm install --frozen-lockfile" ;;
  yarn)  install_cmd="yarn install --frozen-lockfile" ;;
  bun)   install_cmd="bun install --frozen-lockfile" ;;
  pip)   install_cmd="pip install -r requirements.txt" ;;
  uv)    install_cmd="pip install uv && uv pip install -r requirements.txt" ;;
  *)     install_cmd="npm ci" ;;
esac

# Lint commands derived from hooks
hooks_pre_commit=$(jq -r '.hooks.pre_commit // [] | .[]' <<<"$profile_json")
lint_cmd="echo 'no lint configured'"
typecheck_cmd="echo 'no typecheck configured'"
test_cmd="echo 'no test configured'"

case "$lang" in
  typescript|javascript)
    if echo "$hooks_pre_commit" | grep -Fxq "eslint"; then
      lint_cmd="${pkg_mgr} run lint"
      [[ "$pkg_mgr" == "npm" ]] && lint_cmd="npm run lint"
    elif echo "$hooks_pre_commit" | grep -Fxq "biome"; then
      lint_cmd="${pkg_mgr} run lint"
      [[ "$pkg_mgr" == "npm" ]] && lint_cmd="npm run lint"
    fi
    typecheck_cmd="${pkg_mgr} run typecheck 2>/dev/null || npx tsc --noEmit"
    [[ "$pkg_mgr" == "npm" ]] && typecheck_cmd="npm run typecheck 2>/dev/null || npx tsc --noEmit"
    test_cmd="${pkg_mgr} test"
    [[ "$pkg_mgr" == "npm" ]] && test_cmd="npm test"
    ;;
  python)
    if echo "$hooks_pre_commit" | grep -Fxq "ruff"; then
      lint_cmd="ruff check ."
    elif echo "$hooks_pre_commit" | grep -Fxq "flake8"; then
      lint_cmd="flake8 ."
    fi
    test_cmd="pytest"
    ;;
esac

# Monorepo path filters
path_filters=""
workspaces_json=$(jq -r '.workspaces // {}' <<<"$profile_json")
if [[ "$workspaces_json" != "{}" ]]; then
  workspace_paths=$(jq -r 'keys[]' <<<"$workspaces_json" 2>/dev/null || true)
  if [[ -n "$workspace_paths" ]]; then
    path_filters="    paths:"$'\n'
    while IFS= read -r wp; do
      if ! [[ "$wp" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]]; then
        nyann::warn "skipping workspace path with unsafe characters: $wp"
        continue
      fi
      path_filters="${path_filters}      - '${wp}/**'"$'\n'
    done <<<"$workspace_paths"
  fi
fi

# --- Substitute variables in template ----------------------------------------

workflow=$(cat "$template_file")
workflow="${workflow//\$\{BASE_BRANCHES\}/$base_branches}"
workflow="${workflow//\$\{NODE_VERSION\}/$node_version}"
workflow="${workflow//\$\{PYTHON_VERSION\}/$python_version}"
workflow="${workflow//\$\{GO_VERSION\}/$go_version}"
workflow="${workflow//\$\{PACKAGE_MANAGER\}/$pkg_mgr}"
workflow="${workflow//\$\{INSTALL_CMD\}/$install_cmd}"
workflow="${workflow//\$\{LINT_CMD\}/$lint_cmd}"
workflow="${workflow//\$\{TYPECHECK_CMD\}/$typecheck_cmd}"
workflow="${workflow//\$\{TEST_CMD\}/$test_cmd}"

if [[ -n "$path_filters" ]]; then
  workflow="${workflow//\$\{PATH_FILTERS\}/$path_filters}"
else
  workflow="${workflow//\$\{PATH_FILTERS\}/}"
fi

# --- Write output (marker-idempotent) ----------------------------------------

write_workflow() {
  local out_path="$1" marker_start="$2" marker_end="$3" content="$4"

  [[ -L "$out_path" ]] && nyann::die "refusing to write workflow via symlink: $out_path"

  local marked="${marker_start}
${content}
${marker_end}"

  mkdir -p "$(dirname "$out_path")"

  local wtmp
  wtmp=$(mktemp -t nyann-ci.XXXXXX)

  if [[ -f "$out_path" ]]; then
    if grep -Fq "$marker_start" "$out_path" && grep -Fq "$marker_end" "$out_path"; then
      local before after
      before=$(sed -n "1,/^${marker_start}/{ /^${marker_start}/d; p; }" "$out_path")
      after=$(sed -n "/^${marker_end}/,\${ /^${marker_end}/d; p; }" "$out_path")
      {
        [[ -n "$before" ]] && printf '%s\n' "$before"
        printf '%s\n' "$marked"
        [[ -n "$after" ]] && printf '%s\n' "$after"
      } > "$wtmp"
      mv "$wtmp" "$out_path"
      nyann::log "regenerated workflow (markers preserved): $out_path"
    elif $allow_merge; then
      printf '\n%s\n' "$marked" >> "$out_path"
      nyann::warn "appended marked block to existing file (user content above preserved): $out_path"
    else
      nyann::warn "skip $out_path (file exists without nyann markers)"
      nyann::warn "  pass --allow-merge-existing to append a marked block (preserves your workflow)"
      rm -f "$wtmp"
      return 0
    fi
  else
    printf '%s\n' "$marked" > "$out_path"
    nyann::log "created workflow: $out_path"
  fi
  rm -f "$wtmp" 2>/dev/null || true
}

CI_MARKER_START="# nyann:ci:start"
CI_MARKER_END="# nyann:ci:end"
ci_path="$target/.github/workflows/ci.yml"

if [[ "$dry_run" == "true" ]]; then
  printf '%s\n' "${CI_MARKER_START}"
  printf '%s\n' "$workflow"
  printf '%s\n' "${CI_MARKER_END}"
  if $governance; then
    gov_template_file="${templates_dir}/governance-check.yml"
    if [[ -f "$gov_template_file" ]]; then
      gov_workflow=$(cat "$gov_template_file")
      gov_workflow="${gov_workflow//\$\{BASE_BRANCHES\}/$base_branches}"
      if [[ -n "$path_filters" ]]; then
        gov_workflow="${gov_workflow//\$\{PATH_FILTERS\}/$path_filters}"
      else
        gov_workflow="${gov_workflow//\$\{PATH_FILTERS\}/}"
      fi
      printf '\n---\n'
      printf '# nyann:governance:start\n'
      printf '%s\n' "$gov_workflow"
      printf '# nyann:governance:end\n'
    fi
  fi
  exit 0
fi

write_workflow "$ci_path" "$CI_MARKER_START" "$CI_MARKER_END" "$workflow"

# --- Governance workflow (--governance) --------------------------------------

if $governance; then
  gov_template_file="${templates_dir}/governance-check.yml"
  [[ -f "$gov_template_file" ]] || nyann::die "governance template not found: $gov_template_file"

  gov_workflow=$(cat "$gov_template_file")
  gov_workflow="${gov_workflow//\$\{BASE_BRANCHES\}/$base_branches}"
  if [[ -n "$path_filters" ]]; then
    gov_workflow="${gov_workflow//\$\{PATH_FILTERS\}/$path_filters}"
  else
    gov_workflow="${gov_workflow//\$\{PATH_FILTERS\}/}"
  fi

  gov_path="$target/.github/workflows/governance-check.yml"
  write_workflow "$gov_path" "# nyann:governance:start" "# nyann:governance:end" "$gov_workflow"
fi
