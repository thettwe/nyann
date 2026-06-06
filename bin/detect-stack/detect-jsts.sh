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
  # Lock file precedence: pnpm-lock.yaml > yarn.lock > bun.lock(b) >
  # package-lock.json, following ecosystem convention. Both Bun
  # lockfiles are checked: `bun.lockb` (legacy binary, Bun <1.2) and
  # `bun.lock` (text, the Bun 1.2+ default) — a project on modern Bun
  # ships only `bun.lock` and must not fall through to the npm default.
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
  elif [[ -f "$path/bun.lock" ]]; then
    package_manager='"bun"'
    signal_lock=1
    add_reason "Found bun.lock (text lockfile) → package_manager = bun"
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
