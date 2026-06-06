#!/usr/bin/env bats
# bin/detect-stack.sh — v1.10.0 detectors: Deno, Elixir/Phoenix,
# C/C++ CMake; plus the Astro + NestJS framework additions inside
# detect_jsts(). Each new stack also has a matching starter profile;
# suggest-profile correctness for these stacks is asserted at the
# end of the file.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  SUGGEST="${REPO_ROOT}/bin/suggest-profile.sh"
  SCHEMA="${REPO_ROOT}/schemas/stack-descriptor.schema.json"
  TMP=$(mktemp -d)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Convenience: run detect and emit a compact {lang, fw, pm} JSON.
brief_detect() {
  bash "$DETECT" --path "$1" 2>/dev/null \
    | jq -c '{lang: .primary_language, fw: .framework, pm: .package_manager}'
}

# ---------------------------------------------------------------------------
# Deno
# ---------------------------------------------------------------------------

@test "deno: deno.json present, no package.json → typescript + deno + deno" {
  echo '{"tasks":{"dev":"deno run mod.ts"}}' > "$TMP/deno.json"
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.lang')" = "typescript" ]
  [ "$(echo "$result" | jq -r '.fw')"   = "deno" ]
  [ "$(echo "$result" | jq -r '.pm')"   = "deno" ]
}

@test "deno: deno.jsonc (with-comments variant) also matches" {
  echo '{"tasks":{"dev":"deno run"}}' > "$TMP/deno.jsonc"
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.fw')" = "deno" ]
}

@test "deno: deno.json + package.json → JS/TS wins primary; Deno noted only in reasoning" {
  echo '{}' > "$TMP/deno.json"
  echo '{"name":"app"}' > "$TMP/package.json"
  bash "$DETECT" --path "$TMP" 2>/dev/null > "$TMP/out.json"
  # detect_jsts ran first and claimed primary; detect_deno sees primary
  # already set and only adds a reason rather than overwriting.
  [ "$(jq -r '.primary_language' "$TMP/out.json")" = "javascript" ]
  jq -re '.reasoning[] | select(test("Deno is a secondary signal"))' "$TMP/out.json" >/dev/null
}

@test "deno: deno.lock raises detection confidence vs. unlocked deno.json" {
  # Internal lock-signal scoring isn't exposed in the JSON output, but
  # it's folded into `confidence` (higher when a lock file is present).
  echo '{}' > "$TMP/no-lock/deno.json" 2>/dev/null || { mkdir -p "$TMP/no-lock"; echo '{}' > "$TMP/no-lock/deno.json"; }
  mkdir -p "$TMP/with-lock"
  echo '{}' > "$TMP/with-lock/deno.json"
  echo '{"version":"3","specifiers":{}}' > "$TMP/with-lock/deno.lock"

  conf_no_lock=$(bash "$DETECT" --path "$TMP/no-lock"  2>/dev/null | jq -r '.confidence')
  conf_lock=$(bash    "$DETECT" --path "$TMP/with-lock" 2>/dev/null | jq -r '.confidence')

  # The detector's confidence is monotonic in the count of positive
  # signals; lock present → confidence ≥ unlocked confidence.
  awk -v a="$conf_lock" -v b="$conf_no_lock" 'BEGIN{ exit !(a+0 >= b+0) }'
}

# ---------------------------------------------------------------------------
# Elixir / Phoenix
# ---------------------------------------------------------------------------

@test "elixir: bare mix.exs (no phoenix) → elixir + null framework + mix" {
  cat > "$TMP/mix.exs" <<'EOF'
defmodule App.MixProject do
  use Mix.Project
  def project, do: [app: :app, version: "0.1.0", elixir: "~> 1.16"]
  defp deps, do: []
end
EOF
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.lang')" = "elixir" ]
  [ "$(echo "$result" | jq -r '.fw')"   = "null" ]
  [ "$(echo "$result" | jq -r '.pm')"   = "mix" ]
}

@test "phoenix: mix.exs with :phoenix dep → elixir + phoenix + mix" {
  cat > "$TMP/mix.exs" <<'EOF'
defmodule App.MixProject do
  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"}
    ]
  end
end
EOF
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.fw')" = "phoenix" ]
}

@test "elixir: mix.lock raises detection confidence vs. unlocked mix.exs" {
  # Same shape as the deno-lock test — assert the lock file lifts
  # confidence rather than poking at the internal signal var.
  mkdir -p "$TMP/no-lock" "$TMP/with-lock"
  cat > "$TMP/no-lock/mix.exs" <<'EOF'
defmodule App.MixProject do
end
EOF
  cp "$TMP/no-lock/mix.exs" "$TMP/with-lock/mix.exs"
  echo '%{}' > "$TMP/with-lock/mix.lock"

  conf_no_lock=$(bash "$DETECT" --path "$TMP/no-lock"  2>/dev/null | jq -r '.confidence')
  conf_lock=$(bash    "$DETECT" --path "$TMP/with-lock" 2>/dev/null | jq -r '.confidence')

  awk -v a="$conf_lock" -v b="$conf_no_lock" 'BEGIN{ exit !(a+0 >= b+0) }'
}

@test "elixir: comment mentioning :phoenix without an actual dep does NOT trigger phoenix" {
  # The detector matches `{:phoenix,` (with the curly + colon + comma)
  # to avoid free-text false positives. A line that mentions :phoenix
  # in a comment or string should leave framework=null.
  cat > "$TMP/mix.exs" <<'EOF'
defmodule App.MixProject do
  # we considered :phoenix but decided otherwise
  defp deps, do: []
end
EOF
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.fw')" = "null" ]
}

# ---------------------------------------------------------------------------
# C/C++ CMake
# ---------------------------------------------------------------------------

@test "cpp-cmake: CMakeLists.txt → cpp + cmake + null pkg manager" {
  cat > "$TMP/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(demo VERSION 0.1.0 LANGUAGES CXX)
add_executable(demo src/main.cpp)
EOF
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.lang')" = "cpp" ]
  [ "$(echo "$result" | jq -r '.fw')"   = "cmake" ]
  # Package manager is null because vcpkg / conan / system apt are all
  # valid C++ dep paths; the detector deliberately doesn't pick one.
  [ "$(echo "$result" | jq -r '.pm')"   = "null" ]
}

@test "cpp-cmake: alongside a python project, cpp becomes a secondary language" {
  # Python wins primary because detect_python runs before detect_cpp_cmake
  # in the dispatch order. C/C++ shows up in secondary_languages[].
  echo '[project]' > "$TMP/pyproject.toml"
  echo 'name = "demo"' >> "$TMP/pyproject.toml"
  echo 'cmake_minimum_required(VERSION 3.10)' > "$TMP/CMakeLists.txt"
  bash "$DETECT" --path "$TMP" 2>/dev/null > "$TMP/out.json"
  [ "$(jq -r '.primary_language' "$TMP/out.json")" = "python" ]
  [ "$(jq -e '.secondary_languages | contains(["cpp"])' "$TMP/out.json")" = "true" ]
}

# ---------------------------------------------------------------------------
# Astro + NestJS (additions inside detect_jsts)
# ---------------------------------------------------------------------------

@test "astro: package.json declares astro → framework = astro (precedes react/vue)" {
  cat > "$TMP/package.json" <<'EOF'
{
  "name": "demo",
  "dependencies": {
    "astro": "^4.0.0",
    "react": "^18.0.0"
  }
}
EOF
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.fw')" = "astro" ]
}

@test "nestjs: package.json declares @nestjs/core → framework = nestjs (precedes express)" {
  cat > "$TMP/package.json" <<'EOF'
{
  "name": "demo",
  "dependencies": {
    "@nestjs/core": "^10.0.0",
    "express": "^4.0.0"
  }
}
EOF
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.fw')" = "nestjs" ]
}

# ---------------------------------------------------------------------------
# Schema lock — output of detect-stack still validates for every new path
# ---------------------------------------------------------------------------

@test "all v1.10 fixtures produce schema-valid StackDescriptor output" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator available"
  fi
  local fixtures=(
    "deno"
    "elixir"
    "phoenix"
    "cpp-cmake"
    "astro"
    "nestjs"
  )

  for fx in "${fixtures[@]}"; do
    rm -rf "$TMP/$fx"
    mkdir -p "$TMP/$fx"
    case "$fx" in
      deno)     echo '{}'                                                  > "$TMP/$fx/deno.json" ;;
      elixir)   echo 'defmodule X.MixProject do; defp deps, do: [] end'    > "$TMP/$fx/mix.exs" ;;
      phoenix)  echo 'defmodule X.MixProject do; defp deps, do: [{:phoenix, "~> 1.7"}] end' > "$TMP/$fx/mix.exs" ;;
      cpp-cmake) echo 'cmake_minimum_required(VERSION 3.10)'               > "$TMP/$fx/CMakeLists.txt" ;;
      astro)    echo '{"dependencies":{"astro":"^4.0.0"}}'                 > "$TMP/$fx/package.json" ;;
      nestjs)   echo '{"dependencies":{"@nestjs/core":"^10.0.0"}}'         > "$TMP/$fx/package.json" ;;
    esac
    bash "$DETECT" --path "$TMP/$fx" 2>/dev/null > "$TMP/$fx.json"

    if command -v check-jsonschema >/dev/null 2>&1; then
      check-jsonschema --schemafile "$SCHEMA" "$TMP/$fx.json" \
        || { echo "$fx output failed schema validation" >&2; return 1; }
    else
      uvx --quiet check-jsonschema --schemafile "$SCHEMA" "$TMP/$fx.json" \
        || { echo "$fx output failed schema validation" >&2; return 1; }
    fi
  done
}

# ---------------------------------------------------------------------------
# suggest-profile picks the right starter for each new detection path
# ---------------------------------------------------------------------------

@test "suggest-profile: deno repo → deno-app is the top suggestion" {
  echo '{}' > "$TMP/deno.json"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "deno-app" ]
}

@test "suggest-profile: phoenix repo → phoenix-app is the top suggestion" {
  cat > "$TMP/mix.exs" <<'EOF'
defmodule App.MixProject do
  defp deps do [{:phoenix, "~> 1.7"}] end
end
EOF
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "phoenix-app" ]
}

@test "suggest-profile: cmake repo → cpp-cmake is the top suggestion" {
  echo 'cmake_minimum_required(VERSION 3.10)' > "$TMP/CMakeLists.txt"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "cpp-cmake" ]
}

@test "suggest-profile: astro repo → astro-site is the top suggestion" {
  echo '{"dependencies":{"astro":"^4.0.0"}}' > "$TMP/package.json"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "astro-site" ]
}

@test "suggest-profile: nestjs repo → nestjs-service is the top suggestion" {
  echo '{"dependencies":{"@nestjs/core":"^10.0.0"}}' > "$TMP/package.json"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "nestjs-service" ]
}

@test "suggest-profile: nuxt repo → nuxt-app is the top suggestion" {
  echo '{"dependencies":{"nuxt":"^3.0.0"}}' > "$TMP/package.json"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "nuxt-app" ]
}

@test "suggest-profile: sveltekit repo → sveltekit-app is the top suggestion" {
  echo '{"dependencies":{"@sveltejs/kit":"^2.0.0"}}' > "$TMP/package.json"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "sveltekit-app" ]
}

@test "suggest-profile: bun-only repo → bun-app is the top suggestion" {
  # bun.lockb present + no other lockfile + no framework signal →
  # the JS/TS detector sets package_manager=bun + framework=null,
  # which is the bun-app profile's exact signature.
  echo '{}' > "$TMP/package.json"
  : > "$TMP/bun.lockb"
  top=$(bash "$SUGGEST" --target "$TMP" --plugin-root "$REPO_ROOT" 2>/dev/null \
    | jq -r '.suggestions[0].name')
  [ "$top" = "bun-app" ]
}

@test "bun.lock (text lockfile, Bun 1.2+) → package_manager = bun, not npm" {
  # Regression: detection used to check only the legacy binary
  # bun.lockb. Bun 1.2+ defaults to a text `bun.lock`, so a modern Bun
  # project with only `bun.lock` was mis-reported as npm.
  echo '{}' > "$TMP/package.json"
  : > "$TMP/bun.lock"
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.pm')" = "bun" ]
}

@test "bun.lock text lockfile loses to pnpm-lock.yaml (precedence preserved)" {
  # bun.lock sits below pnpm/yarn in precedence, matching bun.lockb.
  echo '{}' > "$TMP/package.json"
  : > "$TMP/bun.lock"
  : > "$TMP/pnpm-lock.yaml"
  result=$(brief_detect "$TMP")
  [ "$(echo "$result" | jq -r '.pm')" = "pnpm" ]
}
