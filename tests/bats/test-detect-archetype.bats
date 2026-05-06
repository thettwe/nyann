#!/usr/bin/env bats
# v1.6.0 archetype detection: bin/detect-stack.sh emits StackDescriptor.archetype
# for every supported codebase type.
#
# Precedence (per docs/proposals/v1.6.0-project-memory.md):
#   plugin > mobile-app > api-service (artifacts) > web-app (frontend fw)
#   > api-service (server fw) > cli-tool > library > unknown
#
# These tests use existing fixtures where possible and create minimal
# in-test fixtures for the cases not already covered.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  TMP=$(mktemp -d -t nyann-archetype.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Helper: run detect-stack and pull .archetype from the result.
arch_for() {
  bash "$DETECT" --path "$1" 2>/dev/null | jq -r '.archetype'
}

# ---- plugin ----------------------------------------------------------------

@test "plugin archetype: .claude-plugin/plugin.json (nyann itself)" {
  result=$(arch_for "${REPO_ROOT}")
  [ "$result" = "plugin" ]
}

@test "plugin archetype takes precedence over server framework signals" {
  # A repo with both a plugin manifest AND a server framework signal
  # should still classify as plugin (highest precedence).
  mkdir -p "$TMP/.claude-plugin"
  echo '{"name":"foo","version":"1.0.0"}' > "$TMP/.claude-plugin/plugin.json"
  # Add a Spring Boot signal too.
  echo '<project><dependencies><dependency><artifactId>spring-boot-starter</artifactId></dependency></dependencies></project>' > "$TMP/pom.xml"
  result=$(arch_for "$TMP")
  [ "$result" = "plugin" ]
}

# ---- mobile-app ------------------------------------------------------------

@test "mobile-app archetype: flutter fixture" {
  result=$(arch_for "${REPO_ROOT}/tests/fixtures/flutter-app")
  [ "$result" = "mobile-app" ]
}

# ---- api-service: artifact-based -------------------------------------------

@test "api-service archetype: openapi.yaml present" {
  mkdir -p "$TMP"
  echo 'openapi: 3.0.0' > "$TMP/openapi.yaml"
  echo '{"name":"foo","version":"1.0.0"}' > "$TMP/package.json"
  result=$(arch_for "$TMP")
  [ "$result" = "api-service" ]
}

@test "api-service archetype: .proto file present" {
  mkdir -p "$TMP"
  echo 'syntax = "proto3";' > "$TMP/api.proto"
  echo 'module foo' > "$TMP/go.mod"
  result=$(arch_for "$TMP")
  [ "$result" = "api-service" ]
}

# ---- api-service: server framework -----------------------------------------

@test "api-service archetype: spring-boot detected" {
  result=$(arch_for "${REPO_ROOT}/tests/fixtures/java-spring")
  [ "$result" = "api-service" ]
}

@test "api-service archetype: dotnet aspnet detected" {
  result=$(arch_for "${REPO_ROOT}/tests/fixtures/dotnet-api")
  [ "$result" = "api-service" ]
}

# ---- web-app ---------------------------------------------------------------

@test "web-app archetype: next.js fixture" {
  result=$(arch_for "${REPO_ROOT}/tests/fixtures/jsts-empty")
  [ "$result" = "web-app" ]
}

# ---- cli-tool --------------------------------------------------------------

@test "cli-tool archetype: package.json with bin field" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"my-cli","version":"1.0.0","bin":{"my-cli":"./bin/cli.js"}}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

@test "cli-tool archetype: package.json with bin as a string (npm allows)" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"my-cli","version":"1.0.0","bin":"./bin/cli.js"}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

@test "library archetype: empty bin object (\"bin\":{}) does NOT trigger cli-tool" {
  # Empty bin object is the npm-scaffolder convention for "no binaries
  # declared yet". The detector must check length, not just nullness:
  # `(.bin | length) > 0` rejects {}/[]/"" while accepting real entries.
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"my-lib","version":"1.0.0","main":"./dist/index.js","bin":{}}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "library" ]
}

@test "unknown archetype: empty bin object alone (no main/exports either)" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"weird","version":"1.0.0","bin":{}}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "unknown" ]
}

@test "numeric .bin (\"bin\": 1) does NOT trigger cli-tool false-positive" {
  # Type guard: `.bin: 1` has length 1 but isn't a real entry-point
  # declaration. Without the type guard the length-only check would
  # classify the repo as cli-tool.
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"weird","version":"1.0.0","bin":1,"main":"./index.js"}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "library" ]
}

@test "numeric .main (\"main\": 1) does NOT trigger library false-positive" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"weird","version":"1.0.0","main":1}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "unknown" ]
}

@test "non-object .engines does NOT crash the jq read (signals preserved)" {
  # Some packages set "engines" to a string like ">=18" instead of
  # an object. A bare .engines.vscode access errors out, which
  # would drop ALL three boolean signals (bin / engines.vscode /
  # main). The type guard isolates the access so the .bin signal
  # still fires and the repo classifies as cli-tool.
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"my-cli","version":"1.0.0","bin":{"my-cli":"./bin/cli.js"},"engines":">=18"}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

@test "non-object .engines on a library still resolves correctly" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"my-lib","version":"1.0.0","main":"./dist/index.js","engines":">=18"}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "library" ]
}

@test "mobile-app archetype: React Native (react-native dep)" {
  # detect_jsts classifies the framework as `react`, which would
  # otherwise route the repo to web-app. The archetype block must
  # catch react-native deps and reclassify to mobile-app.
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"rn-app","version":"1.0.0","dependencies":{"react":"18.2.0","react-native":"0.73.0"}}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "mobile-app" ]
}

@test "mobile-app archetype: Expo (expo dep without explicit react-native)" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"expo-app","version":"1.0.0","dependencies":{"expo":"~50.0.0","react":"18.2.0"}}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "mobile-app" ]
}

@test "mobile-app archetype: @react-native-community/cli scoped package" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"rn-app","version":"1.0.0","devDependencies":{"@react-native-community/cli":"^11.0.0"},"dependencies":{"react":"18.2.0"}}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "mobile-app" ]
}

@test "Next.js without react-native still classifies as web-app (no false-positive)" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"web-app","version":"1.0.0","dependencies":{"next":"14.0.0","react":"18.2.0"}}
JSON
  cat > "$TMP/next.config.js" <<'JS'
module.exports = {};
JS
  result=$(arch_for "$TMP")
  [ "$result" = "web-app" ]
}

@test "cli-tool archetype: Cargo.toml with indented [[bin]] table header" {
  # Some formatters / hand-edits add leading whitespace before table
  # headers. Cargo accepts it; the archetype detector must too.
  mkdir -p "$TMP/src"
  cat > "$TMP/Cargo.toml" <<'TOML'
[package]
name = "indented-bin"
version = "0.1.0"

  [[bin]]
  name = "indented-bin"
  path = "src/main.rs"
TOML
  echo 'fn main() {}' > "$TMP/src/main.rs"
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

@test "cli-tool archetype: Go cmd/main.go" {
  mkdir -p "$TMP/cmd"
  echo 'package main' > "$TMP/cmd/main.go"
  echo 'module foo' > "$TMP/go.mod"
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

@test "cli-tool archetype: pyproject.toml [project.scripts]" {
  mkdir -p "$TMP"
  cat > "$TMP/pyproject.toml" <<'TOML'
[project]
name = "my-cli"
version = "1.0.0"

[project.scripts]
my-cli = "my_cli:main"
TOML
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

@test "cli-tool archetype: Cargo.toml [[bin]]" {
  mkdir -p "$TMP/src"
  cat > "$TMP/Cargo.toml" <<'TOML'
[package]
name = "my-cli"
version = "0.1.0"

[[bin]]
name = "my-cli"
path = "src/main.rs"
TOML
  echo 'fn main() {}' > "$TMP/src/main.rs"
  result=$(arch_for "$TMP")
  [ "$result" = "cli-tool" ]
}

# ---- library ---------------------------------------------------------------

@test "library archetype: package.json with main but no bin" {
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"my-lib","version":"1.0.0","main":"./dist/index.js"}
JSON
  result=$(arch_for "$TMP")
  [ "$result" = "library" ]
}

@test "library archetype: Cargo.toml [lib] without [[bin]]" {
  mkdir -p "$TMP/src"
  cat > "$TMP/Cargo.toml" <<'TOML'
[package]
name = "my-lib"
version = "0.1.0"

[lib]
name = "my_lib"
TOML
  echo 'pub fn hi() {}' > "$TMP/src/lib.rs"
  result=$(arch_for "$TMP")
  [ "$result" = "library" ]
}

@test "library archetype: Package.swift only" {
  mkdir -p "$TMP/Sources/MyLib"
  cat > "$TMP/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "MyLib", products: [.library(name: "MyLib", targets: ["MyLib"])])
SWIFT
  echo 'public func hi() {}' > "$TMP/Sources/MyLib/MyLib.swift"
  result=$(arch_for "$TMP")
  [ "$result" = "library" ]
}

# ---- unknown ---------------------------------------------------------------

@test "unknown archetype: bare directory with no signals" {
  mkdir -p "$TMP"
  echo "# A README" > "$TMP/README.md"
  result=$(arch_for "$TMP")
  [ "$result" = "unknown" ]
}

# ---- precedence sanity-check -----------------------------------------------

@test "precedence: web-app wins over server framework when both signals present" {
  # A Next.js + Express monorepo-ish setup. Frontend framework wins
  # the tie-break per the v1.6.0 design (web-app captures the
  # user-visible primary surface).
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"fullstack","version":"1.0.0","dependencies":{"next":"14.0.0","express":"4.18.0"}}
JSON
  cat > "$TMP/next.config.js" <<'JS'
module.exports = {};
JS
  result=$(arch_for "$TMP")
  [ "$result" = "web-app" ]
}

@test "precedence: web-app wins over api-service when frontend fw + OpenAPI both present" {
  # A Next.js app with a backend OpenAPI spec for its route handlers.
  # The artifact-based api-service check must defer when a frontend
  # framework is detected — the user-visible surface is the web app,
  # not the API.
  mkdir -p "$TMP"
  cat > "$TMP/package.json" <<'JSON'
{"name":"fullstack-with-spec","version":"1.0.0","dependencies":{"next":"14.0.0"}}
JSON
  cat > "$TMP/next.config.js" <<'JS'
module.exports = {};
JS
  echo 'openapi: 3.0.0' > "$TMP/openapi.yaml"
  result=$(arch_for "$TMP")
  [ "$result" = "web-app" ]
}

# ---- backward compat -------------------------------------------------------

@test "legacy DescriptorJSON consumers see archetype field present (not absent)" {
  # Any successful detect-stack run should include archetype in output.
  result=$(bash "$DETECT" --path "${REPO_ROOT}" 2>/dev/null | jq 'has("archetype")')
  [ "$result" = "true" ]
}
