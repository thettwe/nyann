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
