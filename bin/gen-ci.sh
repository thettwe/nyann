#!/usr/bin/env bash
# gen-ci.sh — generate a GitHub Actions CI workflow from the profile's stack.
#
# Usage:
#   gen-ci.sh --profile <path> --stack <path> --target <repo> [--dry-run]
#             [--governance]                 # also generate governance-check.yml
#             [--allow-merge-existing]       # append to existing workflow files
#             [--workspace-configs <path>]   # per-workspace CI matrix (v1.9.0)
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
workspace_configs_path=""

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
    --workspace-configs)    workspace_configs_path="${2:-}"; shift 2 ;;
    --workspace-configs=*)  workspace_configs_path="${1#--workspace-configs=}"; shift ;;
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

base_branches=$(jq -r '
  [.branching.base_branches[] | select(test("^[a-zA-Z0-9][a-zA-Z0-9._/-]*$"))] | join(", ")
' <<<"$profile_json")
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
    _pf_lines=""
    while IFS= read -r wp; do
      [[ "$wp" == "*" ]] && continue
      if ! [[ "$wp" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]]; then
        nyann::warn "skipping workspace path with unsafe characters: $wp"
        continue
      fi
      _pf_lines="${_pf_lines}      - '${wp}/**'"$'\n'
    done <<<"$workspace_paths"
    if [[ -n "$_pf_lines" ]]; then
      path_filters="    paths:"$'\n'"${_pf_lines}"
    fi
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
    if grep -Fxq "$marker_start" "$out_path" && grep -Fxq "$marker_end" "$out_path"; then
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

# --- Per-workspace matrix CI (v1.9.0) ----------------------------------------
# When workspace configs are provided with 2+ workspaces, generate a matrix
# strategy workflow where each workspace gets its own CI job with appropriate
# language setup, working-directory, and commands.

if [[ -n "$workspace_configs_path" && -f "$workspace_configs_path" ]]; then
  ws_count=$(jq 'length' "$workspace_configs_path")
  if (( ws_count >= 2 )); then

    root_pm=$(jq -r '.package_manager // ""' <<<"$stack_json")

    # Build the matrix include array from workspace configs
    matrix_includes=""
    for (( wi=0; wi<ws_count; wi++ )); do
      ws=$(jq -c ".[$wi]" "$workspace_configs_path")
      ws_path=$(jq -r '.path' <<<"$ws")
      ws_lang=$(jq -r '.primary_language // "unknown"' <<<"$ws")
      ws_pm=$(jq -r '.package_manager // null' <<<"$ws")
      ws_ci=$(jq -c '.ci // {}' <<<"$ws")
      ws_hooks=$(jq -r '.hooks.pre_commit // [] | .[]' <<<"$ws")
      ws_name=$(basename "$ws_path")

      # Validate workspace path — same safety check as push-trigger paths
      if ! [[ "$ws_path" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]]; then
        nyann::warn "skipping workspace with unsafe path characters: $ws_path"
        continue
      fi

      # YAML injection guard: ws_lang and ws_pm are scalar values that get
      # emitted as `language: <ws_lang>` / `package-manager: '<ws_pm>'` in
      # the matrix include block. A hostile workspace-configs.json with
      # newlines/quotes in either field would splice attacker-controlled
      # keys into the generated workflow. Restrict both to a strict
      # alphanumeric+underscore+dash grammar — every legitimate language
      # / package-manager identifier nyann emits matches it.
      if ! [[ "$ws_lang" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        nyann::warn "skipping workspace $ws_name: primary_language has unsafe characters: $ws_lang"
        continue
      fi
      case "$ws_pm" in
        null|"") ;;
        *)
          if ! [[ "$ws_pm" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
            nyann::warn "skipping workspace $ws_name: package_manager has unsafe characters: $ws_pm"
            continue
          fi
          ;;
      esac

      # Honor per-workspace ci.* toggles so a workspace can opt out of
      # CI entirely (ci.enabled=false) or skip individual phases
      # (ci.lint/typecheck/test=false). Without these gates, every
      # workspace gets identical Install/Lint/Test steps regardless of
      # what its profile declared.
      # ci.lint/typecheck/test default to true (preserves v1.9.0 behaviour
      # for workspaces that don't declare overrides). NB: cannot use jq's
      # `// true` here — that operator coalesces both `null` AND `false`,
      # which would silently invert explicit `false` settings.
      ws_ci_enabled=$(jq -r 'if has("enabled") then .enabled else true end' <<<"$ws_ci")
      if [[ "$ws_ci_enabled" != "true" ]]; then
        nyann::log "ci-workspaces: skipping $ws_path (ci.enabled=false)"
        continue
      fi
      ws_lint_on=$(jq -r 'if has("lint") then .lint else true end' <<<"$ws_ci")
      ws_typecheck_on=$(jq -r 'if has("typecheck") then .typecheck else true end' <<<"$ws_ci")
      ws_test_on=$(jq -r 'if has("test") then .test else true end' <<<"$ws_ci")

      # YAML injection guard for the four *-run flags. jq normally emits
      # only "true"/"false" for boolean inputs, but if the workspace
      # config supplies a non-boolean (e.g. a quoted string with
      # newlines) jq -r would echo it verbatim into the matrix YAML.
      for _yb in "$ws_ci_enabled" "$ws_lint_on" "$ws_typecheck_on" "$ws_test_on"; do
        case "$_yb" in
          true|false) ;;
          *)
            nyann::warn "skipping workspace $ws_name: ci.* flag has non-boolean value: $_yb"
            continue 2
            ;;
        esac
      done

      # Resolve language version from workspace CI config
      ws_version=""
      case "$ws_lang" in
        typescript|javascript) ws_version=$(jq -r '.node_version // "20"' <<<"$ws_ci") ;;
        python)                ws_version=$(jq -r '.python_version // "3.12"' <<<"$ws_ci") ;;
        go)                    ws_version=$(jq -r '.go_version // "1.22"' <<<"$ws_ci") ;;
        rust)                  ws_version="stable" ;;
        dart)                  ws_version=$(jq -r '.dart_version // "stable"' <<<"$ws_ci") ;;
        *)                     ws_version="latest" ;;
      esac

      # Resolve install command.
      # For JS workspaces without a workspace-local package manager,
      # inherit the root monorepo's package manager so pnpm/yarn/bun
      # repos don't silently degrade to npm.
      [[ "$ws_pm" == "null" ]] && ws_pm=""
      if [[ -z "$ws_pm" ]] && [[ -n "$root_pm" ]]; then
        case "$ws_lang" in
          typescript|javascript) ws_pm="$root_pm" ;;
        esac
      fi
      ws_install=""
      case "$ws_pm" in
        pnpm)    ws_install="pnpm install --frozen-lockfile" ;;
        yarn)    ws_install="yarn install --frozen-lockfile" ;;
        bun)     ws_install="bun install --frozen-lockfile" ;;
        pip)     ws_install="pip install -r requirements.txt" ;;
        uv)      ws_install="pip install uv && uv pip install -r requirements.txt" ;;
        pub)     ws_install="flutter pub get" ;;
        cargo)   ws_install="cargo fetch" ;;
        "")      ws_install="echo 'no install'" ;;
        *)       ws_install="npm ci" ;;
      esac

      # Resolve lint command. Sentinel intentionally avoids embedded quotes
      # so the YAML safety filter (rejects single quotes) doesn't skip
      # workspaces whose language has no profile-declared lint hook.
      ws_lint="echo no lint configured"
      case "$ws_lang" in
        typescript|javascript)
          if echo "$ws_hooks" | grep -Fxq "eslint"; then
            ws_lint="${ws_pm:-npm} run lint"
          fi
          ;;
        python)
          if echo "$ws_hooks" | grep -Fxq "ruff"; then
            ws_lint="ruff check ."
          fi
          ;;
        dart)
          ws_lint="dart analyze" ;;
        go)
          ws_lint="golangci-lint run" ;;
        rust)
          ws_lint="cargo clippy -- -D warnings" ;;
      esac

      # Resolve typecheck command.
      # Defaults are intentionally conservative — typecheck is run only when
      # ci.typecheck=true, so an unset command for unknown languages is fine.
      ws_typecheck="echo no typecheck configured"
      case "$ws_lang" in
        typescript|javascript)
          # tsc lives in node_modules — invoke through the workspace pm so
          # the local toolchain resolves correctly. pm fallback already
          # decided above for JS workspaces.
          case "$ws_pm" in
            pnpm)    ws_typecheck="pnpm exec tsc --noEmit" ;;
            yarn)    ws_typecheck="yarn tsc --noEmit" ;;
            bun)     ws_typecheck="bun x tsc --noEmit" ;;
            *)       ws_typecheck="npx tsc --noEmit" ;;
          esac
          ;;
        python) ws_typecheck="mypy ." ;;
        go)     ws_typecheck="go vet ./..." ;;
        rust)   ws_typecheck="cargo check" ;;
        dart)   ws_typecheck="dart analyze" ;;
      esac

      # Resolve test command (sentinel quote-free for the same reason as lint).
      ws_test="echo no test configured"
      case "$ws_lang" in
        typescript|javascript) ws_test="${ws_pm:-npm} test" ;;
        python)                ws_test="pytest" ;;
        dart)                  ws_test="flutter test" ;;
        go)                    ws_test="go test ./..." ;;
        rust)                  ws_test="cargo test" ;;
      esac

      # Sanitize values for safe YAML embedding: reject single-quotes
      # and newlines which would break the generated YAML structure.
      _yaml_safe=true
      for _yv in "$ws_version" "$ws_install" "$ws_lint" "$ws_typecheck" "$ws_test"; do
        if [[ "$_yv" == *"'"* || "$_yv" == *$'\n'* ]]; then
          nyann::warn "skipping workspace $ws_name: CI value contains unsafe YAML characters"
          _yaml_safe=false
          break
        fi
      done
      $_yaml_safe || continue

      # Build YAML include entry. The *-run booleans (rendered as strings
      # because GH Actions stringifies matrix scalars) gate each step at
      # workflow runtime — see the steps block below. The package-manager
      # field lets the workflow conditionally install pnpm/bun toolchains,
      # matching the single-stack TS template (templates/ci/typescript.yml).
      matrix_includes="${matrix_includes}          - workspace: ${ws_name}
            working-directory: ${ws_path}
            language: ${ws_lang}
            version: '${ws_version}'
            package-manager: '${ws_pm:-npm}'
            install-cmd: '${ws_install}'
            lint-cmd: '${ws_lint}'
            lint-run: '${ws_lint_on}'
            typecheck-cmd: '${ws_typecheck}'
            typecheck-run: '${ws_typecheck_on}'
            test-cmd: '${ws_test}'
            test-run: '${ws_test_on}'
"
    done

    # Compose the multi-workspace workflow
    ws_workflow="# nyann CI workflow — multi-workspace matrix
# Generated by bin/gen-ci.sh from per-workspace profile configs.

name: CI (workspaces)

on:
  push:
    branches: [${base_branches}]
  pull_request:
    branches: [${base_branches}]

jobs:
  workspace-ci:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
${matrix_includes}
    name: \${{ matrix.workspace }} (\${{ matrix.language }})

    steps:
      - uses: actions/checkout@v4

      - name: Setup pnpm
        if: \${{ matrix.package-manager == 'pnpm' }}
        uses: pnpm/action-setup@v4

      - name: Setup Bun
        if: \${{ matrix.package-manager == 'bun' }}
        uses: oven-sh/setup-bun@v2

      - name: Setup Node.js
        if: \${{ matrix.language == 'typescript' || matrix.language == 'javascript' }}
        uses: actions/setup-node@v4
        with:
          node-version: \${{ matrix.version }}

      - name: Setup Python
        if: \${{ matrix.language == 'python' }}
        uses: actions/setup-python@v5
        with:
          python-version: \${{ matrix.version }}

      - name: Setup Go
        if: \${{ matrix.language == 'go' }}
        uses: actions/setup-go@v5
        with:
          go-version: \${{ matrix.version }}

      - name: Setup Rust
        if: \${{ matrix.language == 'rust' }}
        uses: dtolnay/rust-toolchain@stable

      - name: Setup Flutter
        if: \${{ matrix.language == 'dart' }}
        uses: subosito/flutter-action@v2
        with:
          channel: \${{ matrix.version }}

      - name: Install dependencies
        working-directory: \${{ matrix.working-directory }}
        run: \${{ matrix.install-cmd }}

      - name: Lint
        if: \${{ matrix.lint-run == 'true' }}
        working-directory: \${{ matrix.working-directory }}
        run: \${{ matrix.lint-cmd }}

      - name: Type check
        if: \${{ matrix.typecheck-run == 'true' }}
        working-directory: \${{ matrix.working-directory }}
        run: \${{ matrix.typecheck-cmd }}

      - name: Test
        if: \${{ matrix.test-run == 'true' }}
        working-directory: \${{ matrix.working-directory }}
        run: \${{ matrix.test-cmd }}"

    WS_CI_MARKER_START="# nyann:ci-workspaces:start"
    WS_CI_MARKER_END="# nyann:ci-workspaces:end"
    ws_ci_path="$target/.github/workflows/ci-workspaces.yml"

    if [[ "$dry_run" == "true" ]]; then
      printf '%s\n' "${WS_CI_MARKER_START}"
      printf '%s\n' "$ws_workflow"
      printf '%s\n' "${WS_CI_MARKER_END}"
    else
      write_workflow "$ws_ci_path" "$WS_CI_MARKER_START" "$WS_CI_MARKER_END" "$ws_workflow"
    fi
  fi
fi
