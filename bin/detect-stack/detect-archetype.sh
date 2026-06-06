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

# 1b. infra — IaC monorepo signals (Terraform / CDK / Pulumi / Helm /
#     Kustomize). Slotted right after plugin so a Terraform repo with no
#     [[bin]] doesn't fall through to library/cli-tool. The frontend
#     tie-break in step 4 still wins when a repo legitimately mixes
#     Terraform with a web app.
if [[ "$archetype" == "unknown" ]]; then
  # shellcheck source=./detect-iac.sh
  source "${_detect_dir}/detect-iac.sh"
  if nyann::detect_iac "$path"; then
    archetype="infra"
    if [[ -z "${framework//\"/}" || "${framework//\"/}" == "null" ]]; then
      framework="\"$IAC_FRAMEWORK\""
      _fw="$IAC_FRAMEWORK"
    fi
    # When the detected primary language is unknown, promote it to the IaC
    # tool's language (hcl for terraform, yaml for helm/kustomize/k8s/ansible,
    # the inferred polyglot language for cdk/pulumi) so downstream consumers
    # don't crash on enum validation. For CDK/Pulumi the language may already
    # be a concrete code language (e.g. detect_python set python) — only
    # promote when nothing was detected.
    if [[ "$primary_language" == "unknown" && -n "${IAC_LANGUAGE:-}" ]]; then
      primary_language="$IAC_LANGUAGE"
    fi
  fi
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
