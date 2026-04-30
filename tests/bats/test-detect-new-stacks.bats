#!/usr/bin/env bats
# bin/detect-stack.sh — Java, C#/.NET, PHP, Dart/Flutter detection.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  SCHEMA="${REPO_ROOT}/schemas/stack-descriptor.schema.json"
}

# --- Java -------------------------------------------------------------------

@test "java-spring fixture → java + spring-boot + maven" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/java-spring"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "java" ]
  [ "$fw"   = "spring-boot" ]
  [ "$pm"   = "maven" ]
}

@test "java gradle-only project detected when .java files present" {
  tmp=$(mktemp -d)
  echo 'plugins { id "java" }' > "$tmp/build.gradle"
  mkdir -p "$tmp/src"
  echo 'class App {}' > "$tmp/src/App.java"
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "java" ]
  [ "$pm"   = "gradle" ]
  rm -rf "$tmp"
}

@test "gradle without .java files does not trigger java detection" {
  tmp=$(mktemp -d)
  echo 'plugins { id "java" }' > "$tmp/build.gradle"
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" != "java" ]
  rm -rf "$tmp"
}

# --- C# / .NET --------------------------------------------------------------

@test "dotnet-api fixture → csharp + aspnet + dotnet" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/dotnet-api"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "csharp" ]
  [ "$fw"   = "aspnet" ]
  [ "$pm"   = "dotnet" ]
}

@test "sln-only project detects csharp" {
  tmp=$(mktemp -d)
  echo 'Microsoft Visual Studio Solution File' > "$tmp/Example.sln"
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" = "csharp" ]
  rm -rf "$tmp"
}

# --- PHP --------------------------------------------------------------------

@test "php-laravel fixture → php + laravel + composer" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/php-laravel"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "php" ]
  [ "$fw"   = "laravel" ]
  [ "$pm"   = "composer" ]
}

@test "php symfony project detects symfony framework" {
  tmp=$(mktemp -d)
  cat > "$tmp/composer.json" <<'JSON'
{"require": {"symfony/framework-bundle": "^7.0"}}
JSON
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  fw=$(echo "$output" | jq -r '.framework')
  [ "$fw" = "symfony" ]
  rm -rf "$tmp"
}

@test "php composer.lock sets lock signal" {
  tmp=$(mktemp -d)
  echo '{"require": {"php": "^8.2"}}' > "$tmp/composer.json"
  echo '{}' > "$tmp/composer.lock"
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  conf=$(echo "$output" | jq -r '.confidence')
  # manifest (0.5) + lock (0.15) = 0.65
  [ "$conf" = "0.65" ]
  rm -rf "$tmp"
}

# --- Dart / Flutter ----------------------------------------------------------

@test "flutter-app fixture → dart + flutter + pub" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/flutter-app"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "dart" ]
  [ "$fw"   = "flutter" ]
  [ "$pm"   = "pub" ]
}

@test "dart project without flutter SDK has null framework" {
  tmp=$(mktemp -d)
  cat > "$tmp/pubspec.yaml" <<'YAML'
name: plain_dart
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  http: ^1.0.0
YAML
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  [ "$lang" = "dart" ]
  [ "$fw"   = "null" ]
  rm -rf "$tmp"
}

# --- Ruby -------------------------------------------------------------------

@test "ruby-rails fixture → ruby + rails + bundler" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/ruby-rails"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "ruby" ]
  [ "$fw"   = "rails" ]
  [ "$pm"   = "bundler" ]
}

@test "ruby sinatra project detects sinatra framework" {
  tmp=$(mktemp -d)
  cat > "$tmp/Gemfile" <<'GEM'
source "https://rubygems.org"
gem "sinatra"
GEM
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  fw=$(echo "$output" | jq -r '.framework')
  [ "$fw" = "sinatra" ]
  rm -rf "$tmp"
}

@test "ruby Gemfile.lock sets lock signal" {
  tmp=$(mktemp -d)
  echo 'source "https://rubygems.org"' > "$tmp/Gemfile"
  echo 'GEM' > "$tmp/Gemfile.lock"
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  conf=$(echo "$output" | jq -r '.confidence')
  # manifest (0.5) + lock (0.15) = 0.65
  [ "$conf" = "0.65" ]
  rm -rf "$tmp"
}

# --- Extension-count fallback ------------------------------------------------

@test "extension fallback detects .java files" {
  tmp=$(mktemp -d)
  for i in 1 2 3 4 5; do echo "class C$i {}" > "$tmp/C$i.java"; done
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" = "java" ]
  rm -rf "$tmp"
}

@test "extension fallback detects .cs files" {
  tmp=$(mktemp -d)
  for i in 1 2 3 4 5; do echo "class C$i {}" > "$tmp/C$i.cs"; done
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" = "csharp" ]
  rm -rf "$tmp"
}

@test "extension fallback detects .php files" {
  tmp=$(mktemp -d)
  for i in 1 2 3 4 5; do echo "<?php echo $i;" > "$tmp/f$i.php"; done
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" = "php" ]
  rm -rf "$tmp"
}

@test "extension fallback detects .dart files" {
  tmp=$(mktemp -d)
  for i in 1 2 3 4 5; do echo "void main() {}" > "$tmp/f$i.dart"; done
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" = "dart" ]
  rm -rf "$tmp"
}

@test "extension fallback detects .rb files" {
  tmp=$(mktemp -d)
  for i in 1 2 3 4 5; do echo "puts $i" > "$tmp/f$i.rb"; done
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  [ "$lang" = "ruby" ]
  rm -rf "$tmp"
}

# --- Schema validation -------------------------------------------------------

@test "new stack fixtures validate against StackDescriptor schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "need uvx or check-jsonschema installed"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  for fix in java-spring dotnet-api php-laravel flutter-app ruby-rails; do
    tmp=$(mktemp)
    bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/${fix}" > "$tmp"
    run "${validator[@]}" --schemafile "$SCHEMA" "$tmp"
    [ "$status" -eq 0 ]
    rm -f "$tmp"
  done
}
