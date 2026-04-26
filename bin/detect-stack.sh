#!/usr/bin/env bash
# detect-stack.sh — inspect a repo and emit a StackDescriptor JSON.
#
# Usage: detect-stack.sh [--path <dir>]
# Default path is the current working directory.
#
# Output: JSON StackDescriptor to stdout (see schemas/stack-descriptor.schema.json).
# Exit 0 on success; exit 1 on argument or filesystem error.
#
# Covers JS/TS, Python, Go, Rust stacks with confidence scoring and
# schema-validated output.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# --- arg parsing --------------------------------------------------------------

path=""
emit_workspaces=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      path="${2:-}"
      shift 2
      ;;
    --path=*)
      path="${1#--path=}"
      shift
      ;;
    --no-workspaces)
      # Used during recursive workspace iteration so we don't recurse forever.
      emit_workspaces=false
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
detect-stack.sh — emit a StackDescriptor JSON for a repo.

Usage:
  detect-stack.sh [--path <dir>] [--no-workspaces]

Flags:
  --path <dir>       Repo root to inspect. Defaults to the current directory.
  --no-workspaces    Skip the per-workspace sub-descriptor pass (used internally).
  -h, --help         Show this help.
USAGE
      exit 0
      ;;
    *)
      nyann::die "unknown argument: $1"
      ;;
  esac
done

path="${path:-$PWD}"
[[ -d "$path" ]] || nyann::die "path is not a directory: $path"
path="$(cd "$path" && pwd)"

# --- accumulator state --------------------------------------------------------

_reasons=""

add_reason() {
  if [[ -n "$_reasons" ]]; then
    _reasons="${_reasons}"$'\n'"$1"
  else
    _reasons="$1"
  fi
}

# --- JS/TS detection ----------------------------------------------------------
# Returns: primary_language, framework, package_manager (or null each) and
# appends reasoning entries.

primary_language="unknown"
secondary_languages_json='[]'
framework="null"
package_manager="null"

# Confidence-signal flags. Final confidence is a weighted sum:
# explicit manifest 0.5 + CLAUDE.md hint 0.3 + lock file 0.15 + extension
# counts 0.05, ceiling 1.0.
signal_manifest=0
signal_claudemd=0
signal_lock=0
signal_ext=0

detect_jsts() {
  local pkg="$path/package.json"
  [[ -f "$pkg" ]] || return 1

  # Parse top-level deps + devDeps + peerDeps into a flat key set.
  # Fail closed if package.json is not valid JSON.
  local deps
  if ! deps="$(jq -r '
    ((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}))
    | keys_unsorted | .[]
  ' "$pkg" 2>/dev/null)"; then
    add_reason "Found package.json but it is not valid JSON; skipping JS/TS detection"
    return 1
  fi

  signal_manifest=1
  add_reason "Found package.json at repo root → JS/TS stack candidate"

  # Framework detection — first match wins, in precedence order.
  if grep -Fxq 'next' <<<"$deps"; then
    framework='"next"'
    add_reason "package.json declares 'next' → framework = next"
  elif grep -Fxq 'nuxt' <<<"$deps"; then
    framework='"nuxt"'
    add_reason "package.json declares 'nuxt' → framework = nuxt"
  elif grep -Fxq 'remix' <<<"$deps"; then
    framework='"remix"'
    add_reason "package.json declares 'remix' → framework = remix"
  elif grep -Fxq '@sveltejs/kit' <<<"$deps"; then
    framework='"sveltekit"'
    add_reason "package.json declares '@sveltejs/kit' → framework = sveltekit"
  elif grep -Fxq 'react' <<<"$deps"; then
    framework='"react"'
    add_reason "package.json declares 'react' (no higher-level framework) → framework = react"
  elif grep -Fxq 'vue' <<<"$deps"; then
    framework='"vue"'
    add_reason "package.json declares 'vue' → framework = vue"
  elif grep -Fxq 'express' <<<"$deps"; then
    framework='"express"'
    add_reason "package.json declares 'express' → framework = express"
  elif grep -Fxq 'fastify' <<<"$deps"; then
    framework='"fastify"'
    add_reason "package.json declares 'fastify' → framework = fastify"
  else
    add_reason "No known JS/TS framework dependency matched"
  fi

  # Package manager: lock file precedence (pnpm > yarn > bun > npm).
  # Lock file precedence: pnpm-lock.yaml > yarn.lock > bun.lockb >
  # package-lock.json, following ecosystem convention.
  if [[ -f "$path/pnpm-lock.yaml" ]]; then
    package_manager='"pnpm"'
    signal_lock=1
    add_reason "Found pnpm-lock.yaml → package_manager = pnpm"
  elif [[ -f "$path/yarn.lock" ]]; then
    package_manager='"yarn"'
    signal_lock=1
    add_reason "Found yarn.lock → package_manager = yarn"
  elif [[ -f "$path/bun.lockb" ]]; then
    package_manager='"bun"'
    signal_lock=1
    add_reason "Found bun.lockb → package_manager = bun"
  elif [[ -f "$path/package-lock.json" ]]; then
    package_manager='"npm"'
    signal_lock=1
    add_reason "Found package-lock.json → package_manager = npm"
  else
    package_manager='"npm"'
    add_reason "No lock file found; defaulting package_manager = npm"
  fi

  # Language: tsconfig.json presence decides TypeScript vs JavaScript.
  if [[ -f "$path/tsconfig.json" ]]; then
    primary_language="typescript"
    add_reason "Found tsconfig.json → primary_language = typescript"
  else
    primary_language="javascript"
    add_reason "No tsconfig.json → primary_language = javascript"
  fi

  return 0
}

# --- Python detection ---------------------------------------------------------
# Triggered when pyproject.toml / setup.py / requirements.txt / Pipfile exists.
# If JS/TS already matched, Python becomes a secondary language. Otherwise
# Python wins primary. Framework + package manager are inferred from metadata
# and lock files.

detect_python() {
  local has_pyproject=false has_setup_py=false has_requirements=false has_pipfile=false
  [[ -f "$path/pyproject.toml" ]] && has_pyproject=true
  [[ -f "$path/setup.py" ]] && has_setup_py=true
  [[ -f "$path/requirements.txt" ]] && has_requirements=true
  [[ -f "$path/Pipfile" ]] && has_pipfile=true

  if ! $has_pyproject && ! $has_setup_py && ! $has_requirements && ! $has_pipfile; then
    return 1
  fi

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="python"
    add_reason "Found Python project marker → primary_language = python"
  else
    # JS/TS already claimed primary; note Python as secondary.
    secondary_languages_json="$(jq '. + ["python"]' <<<"$secondary_languages_json")"
    add_reason "Python project marker detected alongside $primary_language → secondary language"
  fi

  # --- Framework detection ---------------------------------------------------
  # Grep-based across pyproject.toml + requirements.txt. Case-insensitive so
  # `FastAPI` / `fastapi` / `fastapi-users` all match. Precedence: django >
  # fastapi > flask.
  local dep_blob=""
  [[ -f "$path/pyproject.toml" ]] && dep_blob+="$(<"$path/pyproject.toml")"$'\n'
  [[ -f "$path/requirements.txt" ]] && dep_blob+="$(<"$path/requirements.txt")"$'\n'
  [[ -f "$path/setup.py" ]] && dep_blob+="$(<"$path/setup.py")"$'\n'
  [[ -f "$path/Pipfile" ]] && dep_blob+="$(<"$path/Pipfile")"$'\n'

  # Framework detection — use word-boundary-ish regex so we don't match
  # substrings like `django-rest-framework` → django (intentional match).
  # Only set framework if JS/TS didn't already claim it.
  if [[ "$framework" == "null" ]]; then
    if grep -Eiq '(^|[[:space:]"=<>~!])django([[:space:]"=<>~!-]|$)' <<<"$dep_blob"; then
      framework='"django"'
      add_reason "Python deps reference django → framework = django"
    elif grep -Eiq '(^|[[:space:]"=<>~!])fastapi([[:space:]"=<>~!-]|$)' <<<"$dep_blob"; then
      framework='"fastapi"'
      add_reason "Python deps reference fastapi → framework = fastapi"
    elif grep -Eiq '(^|[[:space:]"=<>~!])flask([[:space:]"=<>~!-]|$)' <<<"$dep_blob"; then
      framework='"flask"'
      add_reason "Python deps reference flask → framework = flask"
    fi
  fi

  # --- Package manager detection --------------------------------------------
  # Skip if JS/TS already set one; the primary-language path owns package_manager.
  if [[ "$package_manager" != "null" ]]; then
    return 0
  fi

  # Lock-file precedence for Python: uv.lock > poetry.lock > Pipfile.lock > pip.
  # setup.py / requirements.txt without lock → pip. pyproject.toml with
  # [tool.poetry] table but no lock → poetry (project declared).
  if [[ -f "$path/uv.lock" ]]; then
    package_manager='"uv"'
    signal_lock=1
    add_reason "Found uv.lock → package_manager = uv"
  elif [[ -f "$path/poetry.lock" ]]; then
    package_manager='"poetry"'
    signal_lock=1
    add_reason "Found poetry.lock → package_manager = poetry"
  elif [[ -f "$path/Pipfile.lock" ]]; then
    package_manager='"pipenv"'
    signal_lock=1
    add_reason "Found Pipfile.lock → package_manager = pipenv"
  elif $has_pyproject && grep -q '^\[tool\.poetry' "$path/pyproject.toml" 2>/dev/null; then
    package_manager='"poetry"'
    add_reason "pyproject.toml contains [tool.poetry] → package_manager = poetry"
  elif $has_pyproject && grep -q '^\[tool\.uv' "$path/pyproject.toml" 2>/dev/null; then
    package_manager='"uv"'
    add_reason "pyproject.toml contains [tool.uv] → package_manager = uv"
  elif $has_pipfile; then
    package_manager='"pipenv"'
    add_reason "Pipfile present → package_manager = pipenv"
  else
    package_manager='"pip"'
    add_reason "No Python lock file / manager metadata → package_manager = pip"
  fi

  return 0
}

# --- Go detection -------------------------------------------------------------
# Triggered when go.mod or go.sum exists. Framework inferred from imports in
# go.mod: gin-gonic/gin, labstack/echo, gofiber/fiber. Package manager always
# "go". When only loose .go files exist (no go.mod), fall through to the
# extension-count path with low confidence.

detect_go() {
  local has_gomod=false
  [[ -f "$path/go.mod" ]] && has_gomod=true
  [[ -f "$path/go.sum" ]] && has_gomod=true

  if ! $has_gomod; then
    return 1
  fi

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="go"
    add_reason "Found go.mod → primary_language = go"
  else
    secondary_languages_json="$(jq '. + ["go"]' <<<"$secondary_languages_json")"
    add_reason "go.mod detected alongside $primary_language → secondary language"
  fi

  # Framework from go.mod require blocks.
  local modfile="$path/go.mod"
  if [[ -f "$modfile" && "$framework" == "null" ]]; then
    if grep -Eq 'github\.com/gin-gonic/gin' "$modfile"; then
      framework='"gin"'
      add_reason "go.mod references gin-gonic/gin → framework = gin"
    elif grep -Eq 'github\.com/labstack/echo' "$modfile"; then
      framework='"echo"'
      add_reason "go.mod references labstack/echo → framework = echo"
    fi
  fi

  # Package manager: always go (its own module system). Only claim when
  # nothing else has.
  if [[ "$package_manager" == "null" ]]; then
    package_manager='"go"'
    signal_lock=1  # go.sum is effectively our lock
    add_reason "Go project → package_manager = go"
  fi

  return 0
}

# --- Rust detection -----------------------------------------------------------
# Triggered when Cargo.toml exists. Framework via dep name. Workspace flag
# from [workspace] members.

detect_rust() {
  local cargo="$path/Cargo.toml"
  [[ -f "$cargo" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="rust"
    add_reason "Found Cargo.toml → primary_language = rust"
  else
    secondary_languages_json="$(jq '. + ["rust"]' <<<"$secondary_languages_json")"
    add_reason "Cargo.toml detected alongside $primary_language → secondary language"
  fi

  # Workspace: Cargo supports its own workspace concept. If present, flag
  # is_monorepo even though no JS/TS-style monorepo tool was detected.
  if grep -Eq '^\[workspace\]' "$cargo"; then
    is_monorepo=true
    monorepo_tool='"cargo-workspace"'
    add_reason "Cargo.toml contains [workspace] → is_monorepo = true"
  fi

  # Framework from dependencies.
  if [[ "$framework" == "null" ]]; then
    if grep -Eq '^actix-web\s*=' "$cargo" || grep -Eq '^actix\s*=' "$cargo"; then
      framework='"actix"'
      add_reason "Cargo.toml references actix → framework = actix"
    elif grep -Eq '^axum\s*=' "$cargo"; then
      framework='"axum"'
      add_reason "Cargo.toml references axum → framework = axum"
    elif grep -Eq '^rocket\s*=' "$cargo"; then
      framework='"rocket"'
      add_reason "Cargo.toml references rocket → framework = rocket"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"cargo"'
    [[ -f "$path/Cargo.lock" ]] && signal_lock=1
    add_reason "Rust project → package_manager = cargo"
  fi

  return 0
}

# --- CLAUDE.md hint parser ----------------------------------------------------
# High-weight signal (0.3 in confidence) when the existing CLAUDE.md names a
# stack that matches (or fills in for) what file detection found. Simple
# keyword search — intentionally conservative. Runs regardless of whether a
# manifest detector matched, so it can boost confidence OR provide the only
# signal when the repo has no manifest.

detect_claudemd_hints() {
  local claudemd="$path/CLAUDE.md"
  [[ -f "$claudemd" ]] || return 1

  local body
  body="$(<"$claudemd")"

  local hit=0

  # Language hints — only fill when primary is still unknown so manifest wins.
  if [[ "$primary_language" == "unknown" ]]; then
    if grep -Eiq '\bpython\b|\bpy3\b' <<<"$body"; then
      primary_language="python"
      hit=1
      add_reason "CLAUDE.md references Python → primary_language = python"
    elif grep -Eiq '\btypescript\b|\btsconfig\b' <<<"$body"; then
      primary_language="typescript"
      hit=1
      add_reason "CLAUDE.md references TypeScript → primary_language = typescript"
    elif grep -Eiq '\bjavascript\b|\bnode\.?js\b' <<<"$body"; then
      primary_language="javascript"
      hit=1
      add_reason "CLAUDE.md references Node/JavaScript → primary_language = javascript"
    elif grep -Eiq '\bgolang\b|\bgo [0-9]' <<<"$body"; then
      primary_language="go"
      hit=1
      add_reason "CLAUDE.md references Go → primary_language = go"
    elif grep -Eiq '\brust\b|\bcargo\b' <<<"$body"; then
      primary_language="rust"
      hit=1
      add_reason "CLAUDE.md references Rust → primary_language = rust"
    elif grep -Eiq '\bswift\b|\bswiftui\b|\buikit\b|\bxcode\b' <<<"$body"; then
      primary_language="swift"
      hit=1
      add_reason "CLAUDE.md references Swift → primary_language = swift"
    elif grep -Eiq '\bkotlin\b|\bandroid\b|\bjetpack\b|\bgradle\b' <<<"$body"; then
      primary_language="kotlin"
      hit=1
      add_reason "CLAUDE.md references Kotlin → primary_language = kotlin"
    elif grep -Eiq '\bbash\b|\bshellcheck\b|\bshell script' <<<"$body"; then
      primary_language="shell"
      hit=1
      add_reason "CLAUDE.md references shell/bash → primary_language = shell"
    fi
  fi

  # Framework hints — fill only when null. Useful when no manifest was found.
  if [[ "$framework" == "null" ]]; then
    if grep -Eiq '\bnext(\.js)?\b' <<<"$body"; then
      framework='"next"'
      hit=1
      add_reason "CLAUDE.md references Next.js → framework = next"
    elif grep -Eiq '\bfastapi\b' <<<"$body"; then
      framework='"fastapi"'
      hit=1
      add_reason "CLAUDE.md references FastAPI → framework = fastapi"
    elif grep -Eiq '\bdjango\b' <<<"$body"; then
      framework='"django"'
      hit=1
      add_reason "CLAUDE.md references Django → framework = django"
    elif grep -Eiq '\bflask\b' <<<"$body"; then
      framework='"flask"'
      hit=1
      add_reason "CLAUDE.md references Flask → framework = flask"
    fi
  elif grep -Eiq '\bnext(\.js)?\b|\bfastapi\b|\bdjango\b|\bflask\b' <<<"$body"; then
    # Manifest already matched; CLAUDE.md corroborates — still counts.
    hit=1
    add_reason "CLAUDE.md framework reference corroborates manifest detection"
  fi

  [[ $hit -eq 1 ]] && signal_claudemd=1
  return 0
}

# --- Swift detection ----------------------------------------------------------
# Triggered when Package.swift exists or *.xcodeproj / *.xcworkspace is found.

detect_swift() {
  local spm="$path/Package.swift"
  local has_xcode=false

  if compgen -G "$path/*.xcodeproj" >/dev/null 2>&1 || compgen -G "$path/*.xcworkspace" >/dev/null 2>&1; then
    has_xcode=true
  fi

  [[ -f "$spm" ]] || $has_xcode || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="swift"
    if [[ -f "$spm" ]]; then
      add_reason "Found Package.swift → primary_language = swift"
    else
      add_reason "Found Xcode project → primary_language = swift"
    fi
  else
    secondary_languages_json="$(jq '. + ["swift"]' <<<"$secondary_languages_json")"
    add_reason "Swift project detected alongside $primary_language → secondary language"
  fi

  if [[ "$package_manager" == "null" ]] && [[ -f "$spm" ]]; then
    package_manager='"spm"'
    add_reason "Package.swift → package_manager = spm"
  fi

  return 0
}

# --- Kotlin detection ---------------------------------------------------------
# Triggered when build.gradle.kts or build.gradle exists alongside .kt files.

detect_kotlin() {
  local gradle_kts="$path/build.gradle.kts"
  local gradle="$path/build.gradle"
  local settings_kts="$path/settings.gradle.kts"
  local settings="$path/settings.gradle"

  [[ -f "$gradle_kts" ]] || [[ -f "$gradle" ]] || [[ -f "$settings_kts" ]] || [[ -f "$settings" ]] || return 1

  local kt_count
  kt_count=$(find "$path" \
    -path "$path/node_modules" -prune -o \
    -path "$path/.gradle"      -prune -o \
    -path "$path/build"        -prune -o \
    -path "$path/.git"          -prune -o \
    -type f -name '*.kt' -print 2>/dev/null | wc -l | tr -d ' ')

  (( kt_count > 0 )) || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="kotlin"
    add_reason "Found Gradle build + ${kt_count} .kt files → primary_language = kotlin"
  else
    secondary_languages_json="$(jq '. + ["kotlin"]' <<<"$secondary_languages_json")"
    add_reason "Kotlin project detected alongside $primary_language → secondary language"
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"gradle"'
    add_reason "Gradle project → package_manager = gradle"
  fi

  return 0
}

# --- Shell/Bash detection -----------------------------------------------------
# Shell projects have no manifest file. Detect by looking for a bin/ or scripts/
# directory with .sh files, or a shebang-heavy root. Only fires when primary is
# still unknown.

detect_shell() {
  [[ "$primary_language" != "unknown" ]] && return 0

  local sh_count
  sh_count=$(find "$path" \
    -path "$path/node_modules" -prune -o \
    -path "$path/.venv"        -prune -o \
    -path "$path/.git"          -prune -o \
    -path "$path/dist"          -prune -o \
    -path "$path/build"         -prune -o \
    -type f -name '*.sh' -print 2>/dev/null | wc -l | tr -d ' ')

  if (( sh_count >= 3 )); then
    primary_language="shell"
    add_reason "Found ${sh_count} .sh files → primary_language = shell"
  fi
  return 0
}

# --- Extension-count fallback -------------------------------------------------
# Last-resort signal (0.05) when no manifest matched. Walks the repo counting
# source files per language, ignoring the usual heavy dirs. Whichever language
# has the most files wins — if it beats an "unknown" primary.

detect_by_extension_counts() {
  [[ "$primary_language" != "unknown" ]] && return 0

  # Use find with -prune to avoid walking node_modules / .venv / dist / build / .git.
  local excludes=(
    -path "$path/node_modules" -prune -o
    -path "$path/.venv"        -prune -o
    -path "$path/.git"          -prune -o
    -path "$path/dist"          -prune -o
    -path "$path/build"         -prune -o
    -path "$path/__pycache__"   -prune -o
    -path "$path/target"        -prune -o
  )

  local py ts js go rs sw kt sh
  py=$(find "$path" "${excludes[@]}" -type f -name '*.py' -print 2>/dev/null | wc -l | tr -d ' ')
  ts=$(find "$path" "${excludes[@]}" -type f \( -name '*.ts' -o -name '*.tsx' \) -print 2>/dev/null | wc -l | tr -d ' ')
  js=$(find "$path" "${excludes[@]}" -type f \( -name '*.js' -o -name '*.jsx' -o -name '*.mjs' \) -print 2>/dev/null | wc -l | tr -d ' ')
  go=$(find "$path" "${excludes[@]}" -type f -name '*.go' -print 2>/dev/null | wc -l | tr -d ' ')
  rs=$(find "$path" "${excludes[@]}" -type f -name '*.rs' -print 2>/dev/null | wc -l | tr -d ' ')
  sw=$(find "$path" "${excludes[@]}" -type f -name '*.swift' -print 2>/dev/null | wc -l | tr -d ' ')
  kt=$(find "$path" "${excludes[@]}" -type f -name '*.kt' -print 2>/dev/null | wc -l | tr -d ' ')
  sh=$(find "$path" "${excludes[@]}" -type f -name '*.sh' -print 2>/dev/null | wc -l | tr -d ' ')

  local max=0 winner=""
  for pair in "python:$py" "typescript:$ts" "javascript:$js" "go:$go" "rust:$rs" "swift:$sw" "kotlin:$kt" "shell:$sh"; do
    local name="${pair%:*}" count="${pair#*:}"
    if (( count > max )); then
      max=$count
      winner="$name"
    fi
  done

  if [[ -n "$winner" ]] && (( max > 0 )); then
    primary_language="$winner"
    signal_ext=1
    add_reason "Extension-count fallback: ${max} $winner file(s) → primary_language = $winner"
  fi
}

# --- history signal initializers --------------------------------------------
# These are read by the detectors above (detect_rust may set is_monorepo to
# true for Cargo workspaces) so initialize before dispatch. Git + CHANGELOG
# signals are filled after detection — they don't influence the stack pick.

has_git=false
git_is_empty_repo=false
has_changelog=false
has_semver_tags=false
contributor_count=0
existing_precommit_config="none"
existing_ci="none"
has_claude_md=false
is_monorepo=false
monorepo_tool="null"

# --- dispatch -----------------------------------------------------------------

detect_jsts || true
detect_python || true
detect_go || true
detect_rust || true
detect_swift || true
detect_kotlin || true
detect_shell || true
detect_claudemd_hints || true
detect_by_extension_counts || true

# --- git / history signals (read after detection) ---------------------------

if [[ -d "$path/.git" ]]; then
  has_git=true
  if ! git -C "$path" rev-parse --verify HEAD >/dev/null 2>&1; then
    git_is_empty_repo=true
  else
    contributor_count=$(git -C "$path" shortlog -sn HEAD 2>/dev/null | wc -l | tr -d ' ')
    if git -C "$path" tag -l 'v[0-9]*' 2>/dev/null | grep -Eq '^v[0-9]+\.[0-9]+'; then
      has_semver_tags=true
    fi
  fi
fi

[[ -f "$path/CHANGELOG.md" ]] && has_changelog=true
[[ -f "$path/CLAUDE.md" ]] && has_claude_md=true
[[ -f "$path/.husky/pre-commit" ]] && existing_precommit_config="husky"
[[ -f "$path/.pre-commit-config.yaml" ]] && existing_precommit_config="pre-commit.com"
[[ -d "$path/.github/workflows" ]] && existing_ci="github-actions"

if [[ "$is_monorepo" != "true" ]]; then
  # Only claim JS/TS monorepo tooling if nothing else already set is_monorepo
  # (detect_rust claims cargo-workspace when Cargo.toml has [workspace]).
  if [[ -f "$path/pnpm-workspace.yaml" ]]; then
    is_monorepo=true
    monorepo_tool='"pnpm-workspaces"'
  elif [[ -f "$path/turbo.json" ]]; then
    is_monorepo=true
    monorepo_tool='"turbo"'
  elif [[ -f "$path/nx.json" ]]; then
    is_monorepo=true
    monorepo_tool='"nx"'
  elif [[ -f "$path/lerna.json" ]]; then
    is_monorepo=true
    monorepo_tool='"lerna"'
  fi
fi

# --- Workspace iteration -----------------------------------------------------
# When is_monorepo and --no-workspaces wasn't set, discover workspace dirs
# from the monorepo manifest and run detect-stack.sh --no-workspaces on each.
# Only a subset of fields is kept per workspace (path, primary_language,
# framework, package_manager). Cargo workspaces are deferred.

workspaces_json='[]'

discover_workspaces() {
  # Prints one workspace dir per line on stdout.
  case "$monorepo_tool" in
    '"pnpm-workspaces"')
      # pnpm-workspace.yaml → `packages:` list of globs.
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$path" <<'PY' || true
import os, sys, glob
try:
    import yaml
except ImportError:
    sys.exit(0)
root = sys.argv[1]
cfg = os.path.join(root, 'pnpm-workspace.yaml')
if not os.path.exists(cfg):
    sys.exit(0)
with open(cfg) as f:
    doc = yaml.safe_load(f) or {}
for pat in (doc.get('packages') or []):
    full = os.path.join(root, pat)
    for match in sorted(glob.glob(full)):
        if os.path.isdir(match):
            print(os.path.relpath(match, root))
PY
      fi
      ;;
    '"turbo"'|'"nx"'|'"lerna"')
      # These typically piggyback on yarn/npm workspaces in package.json or a
      # `packages` glob in their own config. Read package.json.workspaces first.
      if [[ -f "$path/package.json" ]]; then
        jq -r '
          (.workspaces // []) as $w
          | (if ($w | type) == "object" then ($w.packages // []) else $w end)[]
        ' "$path/package.json" 2>/dev/null | while IFS= read -r pat; do
          [[ -z "$pat" ]] && continue
          [[ "$pat" == /* || "$pat" == *".."* ]] && continue
          for match in "$path"/$pat; do
            [[ -d "$match" ]] && echo "${match#"$path"/}"
          done
        done
      fi
      ;;
  esac
}

if $emit_workspaces && [[ "$is_monorepo" == "true" ]]; then
  while IFS= read -r ws; do
    [[ -z "$ws" ]] && continue
    sub_path="$path/$ws"
    [[ -d "$sub_path" ]] || continue
    sub=$("${_script_dir}/detect-stack.sh" --path "$sub_path" --no-workspaces 2>/dev/null || true)
    [[ -z "$sub" ]] && continue
    entry=$(jq --arg p "$ws" '{
      path: $p,
      primary_language: .primary_language,
      framework: .framework,
      package_manager: .package_manager
    }' <<<"$sub")
    workspaces_json=$(jq --argjson e "$entry" '. + [$e]' <<<"$workspaces_json")

    # Fold workspace's language into root's secondary_languages so the flat
    # view still surfaces the polyglot nature. Skip the root's own primary.
    ws_lang=$(jq -r '.primary_language' <<<"$sub")
    if [[ -n "$ws_lang" && "$ws_lang" != "unknown" && "$ws_lang" != "$primary_language" ]]; then
      already=$(jq --arg l "$ws_lang" 'any(. == $l)' <<<"$secondary_languages_json")
      if [[ "$already" != "true" ]]; then
        secondary_languages_json=$(jq --arg l "$ws_lang" '. + [$l]' <<<"$secondary_languages_json")
      fi
    fi
  done < <(discover_workspaces)
fi

# --- Confidence computation ---------------------------------------------------
# Weighted confidence sum. Using awk for float math keeps us independent of
# bc/python.

confidence=$(awk -v m="$signal_manifest" -v c="$signal_claudemd" -v l="$signal_lock" -v e="$signal_ext" \
  'BEGIN {
     s = m*0.5 + c*0.3 + l*0.15 + e*0.05;
     if (s > 1.0) s = 1.0;
     if (s < 0.0) s = 0.0;
     printf "%.2f", s;
   }')

# --- emit JSON ----------------------------------------------------------------

jq -n \
  --arg primary_language "$primary_language" \
  --argjson secondary_languages "$secondary_languages_json" \
  --argjson framework "$framework" \
  --argjson package_manager "$package_manager" \
  --argjson is_monorepo "$is_monorepo" \
  --argjson monorepo_tool "$monorepo_tool" \
  --argjson has_git "$has_git" \
  --argjson git_is_empty_repo "$git_is_empty_repo" \
  --argjson has_claude_md "$has_claude_md" \
  --arg existing_precommit_config "$existing_precommit_config" \
  --arg existing_ci "$existing_ci" \
  --argjson contributor_count "$contributor_count" \
  --argjson has_changelog "$has_changelog" \
  --argjson has_semver_tags "$has_semver_tags" \
  --argjson confidence "$confidence" \
  --arg reasoning_raw "$_reasons" \
  --argjson workspaces "$workspaces_json" \
  '{
    primary_language: $primary_language,
    secondary_languages: $secondary_languages,
    framework: $framework,
    package_manager: $package_manager,
    is_monorepo: $is_monorepo,
    monorepo_tool: $monorepo_tool,
    has_git: $has_git,
    git_is_empty_repo: $git_is_empty_repo,
    has_claude_md: $has_claude_md,
    existing_precommit_config: $existing_precommit_config,
    existing_ci: $existing_ci,
    contributor_count: $contributor_count,
    has_changelog: $has_changelog,
    has_semver_tags: $has_semver_tags,
    confidence: $confidence,
    reasoning: ($reasoning_raw | split("\n") | map(select(. != ""))),
    workspaces: $workspaces
  }'
