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
