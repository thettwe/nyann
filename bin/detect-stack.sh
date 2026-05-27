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
# explicit manifest 0.5 + CLAUDE.md hint 0.3 + doc hint 0.2 + lock file 0.15
# + extension counts 0.05, ceiling 1.0.
signal_manifest=0
signal_claudemd=0
signal_docs=0
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
  # NestJS is checked BEFORE express because NestJS depends on express
  # under the hood; without the explicit higher-priority check, every
  # NestJS service would mis-detect as a generic express service.
  # Astro is checked BEFORE react/vue because Astro projects often
  # declare react/vue as integrations but the framework signal is
  # astro itself.
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
  elif grep -Fxq 'astro' <<<"$deps"; then
    framework='"astro"'
    add_reason "package.json declares 'astro' → framework = astro"
  elif grep -Fxq '@nestjs/core' <<<"$deps"; then
    framework='"nestjs"'
    add_reason "package.json declares '@nestjs/core' → framework = nestjs"
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

  # Single awk pass replaces 14+ separate grep invocations. Outputs
  # space-separated flags: lang_hit framework_hit detected_lang detected_fw
  local awk_result
  awk_result=$(awk '
    BEGIN { lang=""; fw="" }
    { L = tolower($0) }
    L ~ /python|py3/      { if (!lang) lang="python" }
    L ~ /typescript|tsconfig/ { if (!lang) lang="typescript" }
    L ~ /javascript|node\.?js/ { if (!lang) lang="javascript" }
    L ~ /golang|go [0-9]/ { if (!lang) lang="go" }
    L ~ /rust|cargo/      { if (!lang) lang="rust" }
    L ~ /swift|swiftui|uikit|xcode/ { if (!lang) lang="swift" }
    L ~ /kotlin|android|jetpack|gradle/ { if (!lang) lang="kotlin" }
    L ~ /bash|shellcheck|shell script/ { if (!lang) lang="shell" }
    L ~ /java|spring.boot|maven|gradle/ { if (!lang) lang="java" }
    L ~ /c#|csharp|\.net|aspnet|dotnet/ { if (!lang) lang="csharp" }
    L ~ /php|laravel|symfony|composer/ { if (!lang) lang="php" }
    L ~ /dart|flutter|pubspec/ { if (!lang) lang="dart" }
    L ~ /ruby|rails|sinatra|bundler|gemfile/ { if (!lang) lang="ruby" }
    L ~ /next(\.js)?/   { if (!fw) fw="next" }
    L ~ /fastapi/       { if (!fw) fw="fastapi" }
    L ~ /django/        { if (!fw) fw="django" }
    L ~ /flask/         { if (!fw) fw="flask" }
    L ~ /spring.boot|quarkus|aspnet|blazor|laravel|symfony|flutter|rails|sinatra/ { fwcorr=1 }
    END { printf "%s\t%s\t%d", lang, fw, fwcorr+0 }
  ' "$claudemd")

  local detected_lang detected_fw fw_corroborate
  IFS=$'\t' read -r detected_lang detected_fw fw_corroborate <<<"$awk_result"

  local hit=0

  if [[ "$primary_language" == "unknown" && -n "$detected_lang" ]]; then
    primary_language="$detected_lang"
    hit=1
    case "$detected_lang" in
      python)     add_reason "CLAUDE.md references Python → primary_language = python" ;;
      typescript) add_reason "CLAUDE.md references TypeScript → primary_language = typescript" ;;
      javascript) add_reason "CLAUDE.md references Node/JavaScript → primary_language = javascript" ;;
      go)         add_reason "CLAUDE.md references Go → primary_language = go" ;;
      rust)       add_reason "CLAUDE.md references Rust → primary_language = rust" ;;
      swift)      add_reason "CLAUDE.md references Swift → primary_language = swift" ;;
      kotlin)     add_reason "CLAUDE.md references Kotlin → primary_language = kotlin" ;;
      shell)      add_reason "CLAUDE.md references shell/bash → primary_language = shell" ;;
      java)       add_reason "CLAUDE.md references Java → primary_language = java" ;;
      csharp)     add_reason "CLAUDE.md references C#/.NET → primary_language = csharp" ;;
      php)        add_reason "CLAUDE.md references PHP → primary_language = php" ;;
      dart)       add_reason "CLAUDE.md references Dart/Flutter → primary_language = dart" ;;
      ruby)       add_reason "CLAUDE.md references Ruby → primary_language = ruby" ;;
    esac
  fi

  if [[ "$framework" == "null" && -n "$detected_fw" ]]; then
    framework="\"$detected_fw\""
    hit=1
    case "$detected_fw" in
      next)    add_reason "CLAUDE.md references Next.js → framework = next" ;;
      fastapi) add_reason "CLAUDE.md references FastAPI → framework = fastapi" ;;
      django)  add_reason "CLAUDE.md references Django → framework = django" ;;
      flask)   add_reason "CLAUDE.md references Flask → framework = flask" ;;
    esac
  elif [[ "$framework" != "null" ]] && (( fw_corroborate == 1 )); then
    hit=1
    add_reason "CLAUDE.md framework reference corroborates manifest detection"
  fi

  [[ $hit -eq 1 ]] && signal_claudemd=1
  return 0
}

# --- Documentation hint parser ------------------------------------------------
# When no manifest matched (or to supplement), scan README.md, docs/prd.md,
# docs/PRD.md, docs/tech-stack.md, docs/architecture.md for stack mentions.
# Lower weight than CLAUDE.md (0.2) since these are informational, not
# prescriptive. Critically: this enables detection in repos that only have
# planning/spec documents and no code yet. Detects ALL languages mentioned,
# assigning the first hit as primary (if still unknown) and subsequent ones
# as secondary.

detect_doc_hints() {
  # Skip when an earlier detector already identified the primary language —
  # doc hints are meant for repos that only have planning docs (no code yet).
  # This avoids false positives from docs that reference many languages
  # descriptively (like READMEs for polyglot detection tools).
  [[ "$primary_language" == "unknown" ]] || return 0

  local -a doc_files=()
  for candidate in \
    "$path/README.md" "$path/readme.md" \
    "$path/docs/prd.md" "$path/docs/PRD.md" \
    "$path/docs/tech-stack.md" "$path/docs/TECH-STACK.md" \
    "$path/docs/architecture.md" "$path/docs/ARCHITECTURE.md" \
    "$path/docs/stack.md" "$path/docs/techstack.md" \
    "$path/PRD.md" "$path/TECH_STACK.md"; do
    [[ -f "$candidate" ]] && doc_files+=("$candidate")
  done

  (( ${#doc_files[@]} > 0 )) || return 1

  # Single awk pass over all doc files. Uses tolower() for case-insensitive
  # matching (IGNORECASE is a gawk extension, not available on macOS awk).
  # Outputs tab-separated list of ALL languages and frameworks found.
  local awk_result
  awk_result=$(awk '
    { L=tolower($0) }
    L ~ /python|py3|fastapi|django|flask|pipenv|poetry/ {
      if (!seen["python"]) { langs=langs "python "; seen["python"]=1 }
    }
    L ~ /typescript|tsconfig/ {
      if (!seen["typescript"]) { langs=langs "typescript "; seen["typescript"]=1 }
    }
    L ~ /javascript|nodejs|node\.js/ {
      if (!seen["javascript"]) { langs=langs "javascript "; seen["javascript"]=1 }
    }
    L ~ /golang|go [0-9]\.[0-9]/ {
      if (!seen["go"]) { langs=langs "go "; seen["go"]=1 }
    }
    L ~ /\brust\b|cargo|actix|tokio|wasm-pack/ {
      if (!seen["rust"]) { langs=langs "rust "; seen["rust"]=1 }
    }
    L ~ /\bswift\b|swiftui|uikit|xcode/ {
      if (!seen["swift"]) { langs=langs "swift "; seen["swift"]=1 }
    }
    L ~ /\bkotlin\b|android|jetpack|compose/ {
      if (!seen["kotlin"]) { langs=langs "kotlin "; seen["kotlin"]=1 }
    }
    L ~ /\bbash\b|shellcheck|shell script/ {
      if (!seen["shell"]) { langs=langs "shell "; seen["shell"]=1 }
    }
    L ~ /\bjava\b|spring.boot|maven|quarkus|micronaut/ {
      if (!seen["java"]) { langs=langs "java "; seen["java"]=1 }
    }
    L ~ /c#|csharp|\.net|aspnet|dotnet|blazor/ {
      if (!seen["csharp"]) { langs=langs "csharp "; seen["csharp"]=1 }
    }
    L ~ /\bphp\b|laravel|symfony|composer/ {
      if (!seen["php"]) { langs=langs "php "; seen["php"]=1 }
    }
    L ~ /\bdart\b|flutter|pubspec/ {
      if (!seen["dart"]) { langs=langs "dart "; seen["dart"]=1 }
    }
    L ~ /\bruby\b|rails|sinatra|bundler|gemfile/ {
      if (!seen["ruby"]) { langs=langs "ruby "; seen["ruby"]=1 }
    }
    L ~ /next\.js|next js|nextjs/ { if (!fw) fw="next" }
    L ~ /\bfastapi\b/              { if (!fw) fw="fastapi" }
    L ~ /\bdjango\b/               { if (!fw) fw="django" }
    L ~ /\bflask\b/                { if (!fw) fw="flask" }
    L ~ /\bnuxt\b/                 { if (!fw) fw="nuxt" }
    L ~ /\bremix\b/                { if (!fw) fw="remix" }
    L ~ /sveltekit|svelte.?kit/    { if (!fw) fw="sveltekit" }
    L ~ /\breact\b/                { if (!fw) fw="react" }
    L ~ /\bvue\b/                  { if (!fw) fw="vue" }
    L ~ /\bexpress\b/              { if (!fw) fw="express" }
    L ~ /spring.boot/              { if (!fw) fw="spring-boot" }
    L ~ /\bgin\b/                  { if (!fw) fw="gin" }
    L ~ /\blaravel\b/              { if (!fw) fw="laravel" }
    L ~ /\brails\b/                { if (!fw) fw="rails" }
    L ~ /\bflutter\b/              { if (!fw) fw="flutter" }
    END { printf "%s\t%s", langs, fw }
  ' "${doc_files[@]}")

  local langs_str fw_str
  IFS=$'\t' read -r langs_str fw_str <<<"$awk_result"

  [[ -z "$langs_str" && -z "$fw_str" ]] && return 1

  local hit=0
  local first=true
  for lang in $langs_str; do
    if [[ "$primary_language" == "unknown" && "$first" == "true" ]]; then
      primary_language="$lang"
      hit=1
      first=false
      add_reason "Documentation references $lang → primary_language = $lang"
    elif [[ "$lang" != "$primary_language" ]]; then
      # Only add if not already in secondary_languages
      if ! jq -e --arg l "$lang" 'index($l)' <<<"$secondary_languages_json" >/dev/null 2>&1; then
        secondary_languages_json="$(jq --arg l "$lang" '. + [$l]' <<<"$secondary_languages_json")"
        hit=1
        add_reason "Documentation references $lang → secondary language"
      fi
    fi
  done

  if [[ "$framework" == "null" && -n "$fw_str" ]]; then
    framework="\"$fw_str\""
    hit=1
    add_reason "Documentation references $fw_str → framework = $fw_str"
  fi

  [[ $hit -eq 1 ]] && signal_docs=1
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

# --- Java detection -----------------------------------------------------------
# Triggered when pom.xml exists, or build.gradle[.kts] exists with .java files
# (and Kotlin didn't already claim primary). Framework: spring-boot, quarkus,
# micronaut from dependency declarations. Package manager: maven or gradle.

detect_java() {
  local has_pom=false has_gradle=false
  [[ -f "$path/pom.xml" ]] && has_pom=true
  [[ -f "$path/build.gradle" || -f "$path/build.gradle.kts" ]] && has_gradle=true

  if ! $has_pom && ! $has_gradle; then
    return 1
  fi

  # When Gradle is present but no pom.xml, require .java files to distinguish
  # from a pure-Kotlin project (which detect_kotlin already handled).
  if ! $has_pom && $has_gradle; then
    local java_count
    java_count=$(find "$path" \
      -path "$path/node_modules" -prune -o \
      -path "$path/.gradle"      -prune -o \
      -path "$path/build"        -prune -o \
      -path "$path/.git"          -prune -o \
      -type f -name '*.java' -print 2>/dev/null | wc -l | tr -d ' ')
    (( java_count > 0 )) || return 1
  fi

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="java"
    if $has_pom; then
      add_reason "Found pom.xml → primary_language = java"
    else
      add_reason "Found Gradle build + .java files → primary_language = java"
    fi
  else
    secondary_languages_json="$(jq '. + ["java"]' <<<"$secondary_languages_json")"
    add_reason "Java project detected alongside $primary_language → secondary language"
  fi

  # Framework detection from dependency declarations.
  local dep_blob=""
  [[ -f "$path/pom.xml" ]] && dep_blob+="$(<"$path/pom.xml")"$'\n'
  [[ -f "$path/build.gradle" ]] && dep_blob+="$(<"$path/build.gradle")"$'\n'
  [[ -f "$path/build.gradle.kts" ]] && dep_blob+="$(<"$path/build.gradle.kts")"$'\n'

  if [[ "$framework" == "null" ]]; then
    if grep -Eq 'spring-boot|org\.springframework\.boot' <<<"$dep_blob"; then
      framework='"spring-boot"'
      add_reason "Dependencies reference Spring Boot → framework = spring-boot"
    elif grep -Eq 'io\.quarkus' <<<"$dep_blob"; then
      framework='"quarkus"'
      add_reason "Dependencies reference Quarkus → framework = quarkus"
    elif grep -Eq 'io\.micronaut' <<<"$dep_blob"; then
      framework='"micronaut"'
      add_reason "Dependencies reference Micronaut → framework = micronaut"
    fi
  fi

  # Package manager: pom.xml → maven, else gradle.
  if [[ "$package_manager" == "null" ]]; then
    if $has_pom; then
      package_manager='"maven"'
      add_reason "pom.xml present → package_manager = maven"
    else
      package_manager='"gradle"'
      add_reason "Gradle build → package_manager = gradle"
    fi
    signal_lock=1
  fi

  return 0
}

# --- C# / .NET detection -----------------------------------------------------
# Triggered when *.csproj, *.sln, or *.fsproj exists at the repo root (or one
# level deep for *.csproj). Framework: aspnet, blazor, maui from SDK/package
# references. Package manager: dotnet.

detect_dotnet() {
  local has_sln=false has_csproj=false has_fsproj=false

  compgen -G "$path/*.sln" >/dev/null 2>&1 && has_sln=true
  if compgen -G "$path/*.csproj" >/dev/null 2>&1 || compgen -G "$path/*/*.csproj" >/dev/null 2>&1; then
    has_csproj=true
  fi
  compgen -G "$path/*.fsproj" >/dev/null 2>&1 && has_fsproj=true

  $has_sln || $has_csproj || $has_fsproj || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="csharp"
    if $has_sln; then
      add_reason "Found .sln file → primary_language = csharp"
    elif $has_csproj; then
      add_reason "Found .csproj file → primary_language = csharp"
    else
      add_reason "Found .fsproj file → primary_language = csharp"
    fi
  else
    secondary_languages_json="$(jq '. + ["csharp"]' <<<"$secondary_languages_json")"
    add_reason ".NET project detected alongside $primary_language → secondary language"
  fi

  # Framework from SDK attribute or package references in csproj files.
  if [[ "$framework" == "null" ]]; then
    local csproj_blob=""
    for f in "$path"/*.csproj "$path"/*/*.csproj; do
      [[ -f "$f" ]] && csproj_blob+="$(<"$f")"$'\n'
    done

    if grep -Eq 'Microsoft\.NET\.Sdk\.Web|Microsoft\.AspNetCore' <<<"$csproj_blob"; then
      if grep -Eq 'Microsoft\.AspNetCore\.Components|Blazor' <<<"$csproj_blob"; then
        framework='"blazor"'
        add_reason "csproj references Blazor components → framework = blazor"
      else
        framework='"aspnet"'
        add_reason "csproj uses Web SDK or AspNetCore → framework = aspnet"
      fi
    elif grep -Eq 'Microsoft\.Maui|UseMaui' <<<"$csproj_blob"; then
      framework='"maui"'
      add_reason "csproj references MAUI → framework = maui"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"dotnet"'
    add_reason ".NET project → package_manager = dotnet"
  fi

  return 0
}

# --- PHP detection ------------------------------------------------------------
# Triggered when composer.json exists. Framework: laravel, symfony from require.
# Package manager: composer.

detect_php() {
  local composer="$path/composer.json"
  [[ -f "$composer" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="php"
    add_reason "Found composer.json → primary_language = php"
  else
    secondary_languages_json="$(jq '. + ["php"]' <<<"$secondary_languages_json")"
    add_reason "PHP project detected alongside $primary_language → secondary language"
  fi

  # Framework from require block.
  if [[ "$framework" == "null" ]]; then
    local require
    require="$(jq -r '(.require // {}) | keys[]' "$composer" 2>/dev/null)" || true
    if grep -Fxq 'laravel/framework' <<<"$require"; then
      framework='"laravel"'
      add_reason "composer.json requires laravel/framework → framework = laravel"
    elif grep -Fxq 'symfony/framework-bundle' <<<"$require"; then
      framework='"symfony"'
      add_reason "composer.json requires symfony/framework-bundle → framework = symfony"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"composer"'
    [[ -f "$path/composer.lock" ]] && signal_lock=1
    add_reason "PHP project → package_manager = composer"
  fi

  return 0
}

# --- Dart / Flutter detection -------------------------------------------------
# Triggered when pubspec.yaml exists. Framework: flutter when flutter SDK is
# declared. Package manager: pub.

detect_dart() {
  local pubspec="$path/pubspec.yaml"
  [[ -f "$pubspec" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="dart"
    add_reason "Found pubspec.yaml → primary_language = dart"
  else
    secondary_languages_json="$(jq '. + ["dart"]' <<<"$secondary_languages_json")"
    add_reason "Dart project detected alongside $primary_language → secondary language"
  fi

  if [[ "$framework" == "null" ]]; then
    if grep -Eq '^\s+flutter:' "$pubspec" || grep -Eq 'flutter:$' "$pubspec"; then
      framework='"flutter"'
      add_reason "pubspec.yaml declares flutter SDK → framework = flutter"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"pub"'
    [[ -f "$path/pubspec.lock" ]] && signal_lock=1
    add_reason "Dart project → package_manager = pub"
  fi

  return 0
}

# --- Ruby detection -----------------------------------------------------------
# Triggered when Gemfile exists. Framework: rails, sinatra from gem declarations.
# Package manager: bundler.

detect_ruby() {
  local gemfile="$path/Gemfile"
  [[ -f "$gemfile" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="ruby"
    add_reason "Found Gemfile → primary_language = ruby"
  else
    secondary_languages_json="$(jq '. + ["ruby"]' <<<"$secondary_languages_json")"
    add_reason "Ruby project detected alongside $primary_language → secondary language"
  fi

  if [[ "$framework" == "null" ]]; then
    local gem_blob
    gem_blob="$(<"$gemfile")"
    if grep -Eq "gem ['\"]rails['\"]" <<<"$gem_blob"; then
      framework='"rails"'
      add_reason "Gemfile declares rails gem → framework = rails"
    elif grep -Eq "gem ['\"]sinatra['\"]" <<<"$gem_blob"; then
      framework='"sinatra"'
      add_reason "Gemfile declares sinatra gem → framework = sinatra"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"bundler"'
    [[ -f "$path/Gemfile.lock" ]] && signal_lock=1
    add_reason "Ruby project → package_manager = bundler"
  fi

  return 0
}

# --- Deno detection -----------------------------------------------------------
# Triggered when deno.json or deno.jsonc exists. Distinguishes Deno
# from Node by precedence: detect_jsts runs first and only matches
# package.json; a Deno-only project (deno.json + no package.json)
# falls through to this detector. When BOTH manifests exist, package.json
# wins (we leave deno as a secondary signal in reasoning).

detect_deno() {
  local manifest=""
  if [[ -f "$path/deno.json" ]]; then
    manifest="deno.json"
  elif [[ -f "$path/deno.jsonc" ]]; then
    manifest="deno.jsonc"
  else
    return 1
  fi

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="typescript"
    add_reason "Found ${manifest} (no package.json) → primary_language = typescript (Deno runtime)"
  else
    add_reason "Found ${manifest} alongside $primary_language → Deno is a secondary signal"
  fi

  if [[ "$framework" == "null" ]]; then
    framework='"deno"'
    add_reason "${manifest} present → framework = deno"
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"deno"'
    [[ -f "$path/deno.lock" ]] && signal_lock=1
    add_reason "Deno project → package_manager = deno (built-in)"
  fi

  return 0
}

# --- Elixir / Phoenix detection ----------------------------------------------
# Triggered when mix.exs exists. Framework = phoenix iff `:phoenix` is
# declared in the deps function; otherwise framework stays null (plain
# Elixir/OTP project). Package manager is always `mix`.

detect_elixir() {
  local mixfile="$path/mix.exs"
  [[ -f "$mixfile" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="elixir"
    add_reason "Found mix.exs → primary_language = elixir"
  else
    secondary_languages_json="$(jq '. + ["elixir"]' <<<"$secondary_languages_json")"
    add_reason "Elixir project detected alongside $primary_language → secondary language"
  fi

  if [[ "$framework" == "null" ]]; then
    # `:phoenix` declared inside the deps function. Match the literal
    # atom anywhere in the file rather than parsing Elixir AST — the
    # false-positive surface (e.g. a comment mentioning :phoenix
    # without a real dep) is small enough to live with, and avoids
    # shelling out to mix itself which would require Elixir installed.
    if grep -Eq '\{[[:space:]]*:phoenix[[:space:]]*,' "$mixfile"; then
      framework='"phoenix"'
      add_reason "mix.exs declares :phoenix dep → framework = phoenix"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"mix"'
    [[ -f "$path/mix.lock" ]] && signal_lock=1
    add_reason "Elixir project → package_manager = mix"
  fi

  return 0
}

# --- C/C++ CMake detection ----------------------------------------------------
# Triggered when CMakeLists.txt exists at the repo root. Framework =
# cmake (the build system itself, since C/C++ has no canonical app
# framework). Package manager stays null — vcpkg / conan are
# out-of-band and not auto-detected here.

detect_cpp_cmake() {
  local cmake="$path/CMakeLists.txt"
  [[ -f "$cmake" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="cpp"
    add_reason "Found CMakeLists.txt → primary_language = cpp"
  else
    secondary_languages_json="$(jq '. + ["cpp"]' <<<"$secondary_languages_json")"
    add_reason "C/C++ project detected alongside $primary_language → secondary language"
  fi

  if [[ "$framework" == "null" ]]; then
    framework='"cmake"'
    add_reason "CMakeLists.txt present → framework = cmake (build system)"
  fi

  # Package manager intentionally stays null — vcpkg / conan / system
  # apt are all valid C++ dependency paths and a CMake repo doesn't
  # disambiguate. Operators can set ci.package_manager in the profile
  # by hand when they know what they're using.

  return 0
}

# --- Shell/Bash detection -----------------------------------------------------
# Shell projects have no manifest file. Detect by looking for a bin/ or scripts/
# directory with .sh files, or a shebang-heavy root. Only fires when primary is
# still unknown.

detect_shell() {
  local sh_count
  sh_count=$(find "$path" \
    -path "$path/node_modules" -prune -o \
    -path "$path/.venv"        -prune -o \
    -path "$path/.git"          -prune -o \
    -path "$path/dist"          -prune -o \
    -path "$path/build"         -prune -o \
    -type f -name '*.sh' -print 2>/dev/null | wc -l | tr -d ' ')

  (( sh_count >= 3 )) || return 0

  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="shell"
    add_reason "Found ${sh_count} .sh files → primary_language = shell"
  else
    secondary_languages_json="$(jq '. + ["shell"]' <<<"$secondary_languages_json")"
    add_reason "Found ${sh_count} .sh files alongside $primary_language → secondary language"
  fi
  return 0
}

# --- Extension-count fallback -------------------------------------------------
# Last-resort signal (0.05) when no manifest matched. Walks the repo counting
# source files per language, ignoring the usual heavy dirs. Whichever language
# has the most files wins — if it beats an "unknown" primary.

detect_by_extension_counts() {
  [[ "$primary_language" != "unknown" ]] && return 0

  # Single find pass counts all source-file extensions via awk, replacing
  # 13 separate find invocations that each walked the same tree.
  local counts
  counts=$(find "$path" \
    -path "$path/node_modules" -prune -o \
    -path "$path/.venv"        -prune -o \
    -path "$path/.git"          -prune -o \
    -path "$path/dist"          -prune -o \
    -path "$path/build"         -prune -o \
    -path "$path/__pycache__"   -prune -o \
    -path "$path/target"        -prune -o \
    -type f -print 2>/dev/null \
  | awk -F. '{ext=tolower($NF)} ext=="py"{py++} ext=="ts"||ext=="tsx"{ts++} ext=="js"||ext=="jsx"||ext=="mjs"{js++} ext=="go"{go++} ext=="rs"{rs++} ext=="swift"{sw++} ext=="kt"{kt++} ext=="sh"{sh++} ext=="java"{jv++} ext=="cs"{cs++} ext=="php"{php++} ext=="dart"{da++} ext=="rb"{rb++} END{printf "%d %d %d %d %d %d %d %d %d %d %d %d %d",py+0,ts+0,js+0,go+0,rs+0,sw+0,kt+0,sh+0,jv+0,cs+0,php+0,da+0,rb+0}')

  local py ts js go rs sw kt sh jv cs php da rb
  read -r py ts js go rs sw kt sh jv cs php da rb <<<"$counts"

  local max=0 winner=""
  for pair in "python:$py" "typescript:$ts" "javascript:$js" "go:$go" "rust:$rs" "swift:$sw" "kotlin:$kt" "shell:$sh" "java:$jv" "csharp:$cs" "php:$php" "dart:$da" "ruby:$rb"; do
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
detect_java || true
detect_dotnet || true
detect_php || true
detect_dart || true
detect_ruby || true
# New v1.10.0 detectors. Ordered after the established stacks so an
# existing detection path can claim primary first; these only set
# primary_language when nothing else matched. detect_deno() runs
# AFTER detect_jsts() so a `deno.json + package.json` polyglot
# stays on the JS/TS path.
detect_deno     || true
detect_elixir   || true
detect_cpp_cmake || true
detect_shell || true
detect_claudemd_hints || true
detect_doc_hints || true
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
          # Scope IFS to newline-only so a workspace pattern like
          # "apps and libs/*" doesn't get word-split on spaces during
          # the unquoted glob expansion. Default IFS=$' \t\n' would
          # split the single pattern into three globs. The IFS change
          # is scoped to this pipe subshell — no restore needed.
          IFS=$'\n'
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

confidence=$(awk -v m="$signal_manifest" -v c="$signal_claudemd" -v d="$signal_docs" -v l="$signal_lock" -v e="$signal_ext" \
  'BEGIN {
     s = m*0.5 + c*0.3 + d*0.2 + l*0.15 + e*0.05;
     if (s > 1.0) s = 1.0;
     if (s < 0.0) s = 0.0;
     printf "%.2f", s;
   }')

# --- archetype detection (v1.6.0) --------------------------------------------
# Codebase archetype — what kind of system is this? Drives archetype-aware
# Project Memory scaffolding when documentation.use_archetype_scaffolds is
# true. Detection is signal-based; profile-declared archetype overrides this
# at scaffold time. The precedence ladder below codifies the rule "the
# user-visible primary surface wins" (frontend over server, mobile over
# generic library, plugin manifest over everything).
#
# Precedence (first match wins, descending specificity):
#   1. plugin       — unambiguous manifest at the repo root
#   2. mobile-app   — language + framework signals
#   3. api-service  — OpenAPI/proto files; OR server framework w/o frontend
#   4. web-app      — frontend framework
#   5. cli-tool     — entry-point binaries (package.json bin, cmd/main.go,
#                     console_scripts, [[bin]] in Cargo.toml)
#   6. library      — published-package signals without entry-point binary
#   7. unknown      — fallback

archetype="unknown"

# Strip framework's surrounding JSON quotes for plain string comparisons.
_fw="${framework//\"/}"

# Read manifests ONCE at the top of the archetype block, stash the
# archetype-relevant booleans, then reuse across the precedence
# ladder. Replaces 3 jq + 3 grep + ~6 file reads scattered through
# the branches with 1 jq + 2 greps + 2 file reads.
arch_pkg_has_bin=false
arch_pkg_has_engines_vscode=false
arch_pkg_has_lib_signal=false
if [[ -f "${path}/package.json" ]]; then
  # Each boolean below is type-guarded so a malformed-but-valid
  # package.json does not produce false positives or crash the whole
  # jq program:
  #
  # - `.bin` is treated as a real entry-point only when it's a
  #   non-empty object or non-empty string. A numeric `"bin": 1`
  #   has length 1 but isn't a binary declaration; the type guard
  #   rejects it. Same shape on `.main / .module / .exports` so an
  #   empty entry-point hint or numeric value doesn't masquerade
  #   as a library.
  # - `.engines.vscode` is read only when `.engines` is an object.
  #   Some packages set `"engines": ">=18"` (a string); a bare
  #   `.engines.vscode` access on a non-object errors out and kills
  #   the entire jq program, dropping ALL three boolean signals.
  #   Wrapping in a type check isolates the access.
  if pkg_arch_tsv=$(jq -r '[
        ((.bin | type) as $t | ($t == "object" or $t == "string") and (.bin | length > 0)),
        ((.engines | type == "object") and (.engines.vscode | type == "string") and (.engines.vscode | length > 0)),
        (
          ((.main // .module // .exports) | type == "string") and
          ((.main // .module // .exports) | length > 0) and
          (((.bin | type) as $t | ($t == "object" or $t == "string") and (.bin | length > 0)) | not)
        )
      ] | @tsv' "${path}/package.json" 2>/dev/null); then
    IFS=$'\t' read -r arch_pkg_has_bin arch_pkg_has_engines_vscode arch_pkg_has_lib_signal <<<"$pkg_arch_tsv"
  fi
fi

arch_cargo_has_bin=false
arch_cargo_has_lib=false
if [[ -f "${path}/Cargo.toml" ]]; then
  cargo_blob="$(<"${path}/Cargo.toml")"
  # `[[:space:]]*` tolerates leading whitespace on the table header
  # (some formatters indent nested tables; cargo accepts it). Without
  # this, an indented `  [[bin]]` would miss the cli-tool signal.
  if grep -qE '^[[:space:]]*\[\[bin\]\]' <<<"$cargo_blob"; then arch_cargo_has_bin=true; fi
  if grep -qE '^[[:space:]]*\[lib\]'     <<<"$cargo_blob"; then arch_cargo_has_lib=true; fi
fi

# 1. plugin — unambiguous manifest signals
#    - .claude-plugin/plugin.json — Claude Code plugins (this repo's own manifest)
#    - manifest.json with manifest_version — browser extensions (Chrome/Firefox/Edge)
#    - package.json with engines.vscode — VS Code extensions; the manifest IS
#      package.json with the engines.vscode field, not a separate file
if [[ -f "${path}/.claude-plugin/plugin.json" ]] || \
   [[ "$arch_pkg_has_engines_vscode" == "true" ]] || \
   ( [[ -f "${path}/manifest.json" ]] && jq -e '.manifest_version' "${path}/manifest.json" >/dev/null 2>&1 ); then
  archetype="plugin"
fi

# 2. mobile-app — language/framework signals
if [[ "$archetype" == "unknown" ]]; then
  case "$primary_language" in
    swift)
      # Swift is overwhelmingly iOS/macOS/watchOS app territory in nyann's
      # supported stacks. SwiftPM libraries are detected as `library` below
      # if no app signals are present.
      if [[ -d "${path}/Pods" ]] || [[ -f "${path}/Podfile" ]] || \
         compgen -G "${path}/*.xcodeproj" >/dev/null 2>&1 || \
         compgen -G "${path}/*.xcworkspace" >/dev/null 2>&1; then
        archetype="mobile-app"
      fi
      ;;
    kotlin)
      # Android signals: Gradle + AndroidManifest.xml or app/ module layout.
      if [[ -f "${path}/app/src/main/AndroidManifest.xml" ]] || \
         [[ -f "${path}/AndroidManifest.xml" ]]; then
        archetype="mobile-app"
      fi
      ;;
    dart)
      # Flutter is the only Dart framework nyann supports today; presence of
      # pubspec.yaml + flutter dependency is enough.
      if [[ "$_fw" == "flutter" ]] || \
         { [[ -f "${path}/pubspec.yaml" ]] && grep -q "^  flutter:" "${path}/pubspec.yaml" 2>/dev/null; }; then
        archetype="mobile-app"
      fi
      ;;
    typescript|javascript)
      # React Native: a JS/TS repo with `react-native` (or
      # `@react-native-community/cli` / Expo) in package.json deps.
      # detect_jsts classifies the framework as `react`, which would
      # otherwise route the repo to web-app at step 4. Catch the
      # mobile case here (before the artifact-based api-service step
      # so RN repos with an OpenAPI spec for their backend still land
      # as mobile-app).
      if [[ -f "${path}/package.json" ]] && \
         jq -e '
           (.dependencies // {}) + (.devDependencies // {}) |
           keys |
           any(. == "react-native" or . == "expo" or startswith("@react-native"))
         ' "${path}/package.json" >/dev/null 2>&1; then
        archetype="mobile-app"
      fi
      ;;
  esac
fi

# 3. api-service — OpenAPI / proto / swagger artifacts, EXCEPT when a
#    frontend framework is also detected. Full-stack repos
#    (e.g., Next.js + an OpenAPI spec for the backend route handlers)
#    classify as web-app, not api-service: the frontend is the
#    user-visible primary surface, and the proposal puts web-app
#    ahead of artifact-based api-service for that case.
if [[ "$archetype" == "unknown" ]]; then
  case "$_fw" in
    next|nuxt|remix|sveltekit|react|vue|astro)
      # Frontend framework present — defer to web-app at step 4.
      ;;
    *)
      if [[ -f "${path}/openapi.yaml" ]] || [[ -f "${path}/openapi.yml" ]] || \
         [[ -f "${path}/openapi.json" ]] || [[ -f "${path}/swagger.json" ]] || \
         [[ -f "${path}/api/openapi.yaml" ]] || [[ -f "${path}/spec/openapi.yaml" ]] || \
         compgen -G "${path}/*.proto" >/dev/null 2>&1 || \
         compgen -G "${path}/proto/*.proto" >/dev/null 2>&1; then
        archetype="api-service"
      fi
      ;;
  esac
fi

# 4. web-app — frontend framework signals (covers SPA + full-stack;
#    full-stack reaches here when step 3 deferred because it detected
#    a frontend framework alongside artifact signals).
if [[ "$archetype" == "unknown" ]]; then
  case "$_fw" in
    next|nuxt|remix|sveltekit|react|vue|astro)
      archetype="web-app"
      ;;
  esac
fi

# 5. api-service — server framework with no frontend (re-checked after
#    web-app step so frontend frameworks win the tie-break)
if [[ "$archetype" == "unknown" ]]; then
  case "$_fw" in
    express|fastify|fastapi|flask|django|gin|echo|actix|axum|rocket|phoenix|nestjs| \
    spring-boot|quarkus|micronaut|aspnet|blazor|laravel|symfony|rails|sinatra)
      archetype="api-service"
      ;;
  esac
fi

# 6. cli-tool — entry-point binary signals (uses cached package.json /
#    Cargo.toml booleans from the top of the archetype block).
if [[ "$archetype" == "unknown" ]]; then
  if [[ "$arch_pkg_has_bin" == "true" ]]; then
    archetype="cli-tool"
  elif [[ -f "${path}/cmd/main.go" ]] || compgen -G "${path}/cmd/*/main.go" >/dev/null 2>&1; then
    archetype="cli-tool"
  elif [[ -f "${path}/pyproject.toml" ]] && \
       grep -qE '^\[project\.scripts\]|^\[tool\.poetry\.scripts\]|console_scripts' "${path}/pyproject.toml" 2>/dev/null; then
    archetype="cli-tool"
  elif [[ -f "${path}/setup.py" ]] && grep -q "console_scripts" "${path}/setup.py" 2>/dev/null; then
    archetype="cli-tool"
  elif [[ "$arch_cargo_has_bin" == "true" ]]; then
    archetype="cli-tool"
  fi
fi

# 7. library — published-package signals without entry-point binary
#    (uses cached booleans).
if [[ "$archetype" == "unknown" ]]; then
  if [[ "$arch_pkg_has_lib_signal" == "true" ]]; then
    archetype="library"
  elif [[ "$arch_cargo_has_lib" == "true" && "$arch_cargo_has_bin" == "false" ]]; then
    archetype="library"
  elif [[ -f "${path}/Package.swift" ]]; then
    # SwiftPM project without an .xcodeproj / .xcworkspace at this point
    # is almost always a library distribution.
    archetype="library"
  fi
fi

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
  --arg archetype "$archetype" \
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
    archetype: $archetype,
    confidence: $confidence,
    reasoning: ($reasoning_raw | split("\n") | map(select(. != ""))),
    workspaces: $workspaces
  }'
