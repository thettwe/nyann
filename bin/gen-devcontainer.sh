#!/usr/bin/env bash
# gen-devcontainer.sh — emit a .devcontainer/devcontainer.json
#
# Usage:
#   bin/gen-devcontainer.sh
#     --language <node|python|go|rust|dart|java|dotnet|php|ruby|swift|elixir|cpp>
#     [--name <display-name>]
#     [--target <repo>]
#     [--apply] [--force-overwrite]
#     [--port <int>]              (repeatable; forwards to forwardedPorts)
#     [--feature <ref>]           (repeatable; extra features beyond the base set)
#     [--extension <pub.ext>]     (repeatable; extra VS Code extensions)
#     [--post-create-command <s>] (overrides per-language default)
#     [--cpus <n>] [--memory <NgB>] [--storage <NgB>]
#
# Default behavior is preview-only — without `--apply`, the rendered
# devcontainer.json is printed to stdout. Matches the preview-before-
# mutate convention used by gen-dependency-updater.sh.
#
# When `--apply` is passed, the file lands at:
#   <target>/.devcontainer/devcontainer.json
#
# Idempotency: identical content is a no-op. Different content prints
# a unified diff to stderr and refuses to overwrite unless `--force-
# overwrite` is also passed.
#
# Exit codes:
#   0 — preview rendered OR apply succeeded
#   1 — bad input
#   3 — apply blocked because target file differs (diff already on stderr)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# --- arg parsing -------------------------------------------------------------

language=""
name=""
target=""
apply=false
force_overwrite=false
post_create_command_override=""
post_create_command_set=false
cpus=""
memory=""
storage=""
extra_ports=()
extra_features=()
extra_extensions=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)           language="${2:-}"; shift 2 ;;
    --language=*)         language="${1#--language=}"; shift ;;
    --name)               name="${2:-}"; shift 2 ;;
    --name=*)             name="${1#--name=}"; shift ;;
    --target)             target="${2:-}"; shift 2 ;;
    --target=*)           target="${1#--target=}"; shift ;;
    --apply)              apply=true; shift ;;
    --force-overwrite)    force_overwrite=true; shift ;;
    --port)               extra_ports+=("${2:-}"); shift 2 ;;
    --port=*)             extra_ports+=("${1#--port=}"); shift ;;
    --feature)            extra_features+=("${2:-}"); shift 2 ;;
    --feature=*)          extra_features+=("${1#--feature=}"); shift ;;
    --extension)          extra_extensions+=("${2:-}"); shift 2 ;;
    --extension=*)        extra_extensions+=("${1#--extension=}"); shift ;;
    --post-create-command)   post_create_command_override="${2:-}"; post_create_command_set=true; shift 2 ;;
    --post-create-command=*) post_create_command_override="${1#--post-create-command=}"; post_create_command_set=true; shift ;;
    --cpus)               cpus="${2:-}"; shift 2 ;;
    --cpus=*)             cpus="${1#--cpus=}"; shift ;;
    --memory)             memory="${2:-}"; shift 2 ;;
    --memory=*)           memory="${1#--memory=}"; shift ;;
    --storage)            storage="${2:-}"; shift 2 ;;
    --storage=*)          storage="${1#--storage=}"; shift ;;
    -h|--help)            sed -n '3,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- validate ----------------------------------------------------------------

case "$language" in
  node|python|go|rust|dart|java|dotnet|php|ruby|swift|elixir|cpp) ;;
  "") nyann::die "--language is required (see schemas/devcontainer-config.schema.json for the allowlist)" ;;
  *)  nyann::die "unknown language: $language (see schemas/devcontainer-config.schema.json for the allowlist)" ;;
esac

# Validate optional numeric/format flags. Loop expansion uses the
# `${arr[@]+...}` form so an empty array doesn't trip `set -u`.
for p in ${extra_ports[@]+"${extra_ports[@]}"}; do
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    nyann::die "--port must be an integer 1-65535, got: $p"
  fi
done

if [[ -n "$cpus" ]]; then
  if ! [[ "$cpus" =~ ^[0-9]+$ ]] || (( cpus < 2 || cpus > 32 )); then
    nyann::die "--cpus must be 2-32, got: $cpus"
  fi
fi
if [[ -n "$memory" ]]; then
  [[ "$memory" =~ ^[0-9]+(gb|GB|gib|GiB)$ ]] \
    || nyann::die "--memory must look like 4gb / 8GiB, got: $memory"
fi
if [[ -n "$storage" ]]; then
  [[ "$storage" =~ ^[0-9]+(gb|GB|gib|GiB)$ ]] \
    || nyann::die "--storage must look like 16gb / 32GiB, got: $storage"
fi

# Validate extension IDs match publisher.extension shape so a malformed
# input doesn't end up in the rendered JSON and confuse VS Code at
# container-build time. `${arr[@]+...}` guard for set -u safety.
for ext in ${extra_extensions[@]+"${extra_extensions[@]}"}; do
  [[ "$ext" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] \
    || nyann::die "--extension must look like 'publisher.extension', got: $ext"
done

if $apply; then
  [[ -n "$target" ]] || nyann::die "--apply requires --target <repo>"
  [[ -d "$target" ]] || nyann::die "--target must be an existing directory: $target"
  target="$(cd "$target" && pwd -P)"
fi

# --- snapshot tag ------------------------------------------------------------

plugin_json="${_script_dir}/../.claude-plugin/plugin.json"
nyann_version="unknown"
if [[ -f "$plugin_json" ]]; then
  nyann_version=$(jq -r '.version // "unknown"' "$plugin_json" 2>/dev/null || echo unknown)
fi

# --- per-language defaults ---------------------------------------------------
# Base image, extension list, and postCreateCommand per language. These
# values are kept in step with each other: a base image bump should
# verify the listed extensions still install cleanly (most are
# language-tier so they don't break, but a runtime change can move
# extension dependencies around).
#
# Base image policy:
#   - Microsoft devcontainers/<lang> images where they exist (well-
#     maintained, security-scanned, support multi-arch).
#   - Vendor images for stacks without an MS variant (dart, swift,
#     elixir).
#   - Pinned to a major:minor tag, NOT a digest. Operators who need
#     reproducible bytes should pin to a digest by hand-editing the
#     rendered file; updater bots (gen-dependency-updater for Docker
#     ecosystem) can roll the tag for them.

base_image=""
default_post_create=""
default_extensions=()
case "$language" in
  node)
    base_image="mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm"
    default_post_create="if [ -f package.json ]; then npm ci || npm install; fi"
    default_extensions=(
      "dbaeumer.vscode-eslint"
      "esbenp.prettier-vscode"
      "ms-vscode.vscode-typescript-next"
    )
    ;;
  python)
    base_image="mcr.microsoft.com/devcontainers/python:1-3.12-bookworm"
    default_post_create="if [ -f pyproject.toml ]; then pip install -e . 2>/dev/null || uv sync 2>/dev/null || true; fi"
    default_extensions=(
      "ms-python.python"
      "charliermarsh.ruff"
    )
    ;;
  go)
    base_image="mcr.microsoft.com/devcontainers/go:1-1.22-bookworm"
    default_post_create="if [ -f go.mod ]; then go mod download; fi"
    default_extensions=(
      "golang.go"
    )
    ;;
  rust)
    base_image="mcr.microsoft.com/devcontainers/rust:1-1-bookworm"
    default_post_create="if [ -f Cargo.toml ]; then cargo fetch; fi"
    default_extensions=(
      "rust-lang.rust-analyzer"
      "tamasfe.even-better-toml"
    )
    ;;
  dart)
    # No MS devcontainer image for Dart; use the official dart image.
    base_image="dart:stable"
    default_post_create="if [ -f pubspec.yaml ]; then dart pub get; fi"
    default_extensions=(
      "dart-code.dart-code"
      "dart-code.flutter"
    )
    ;;
  java)
    base_image="mcr.microsoft.com/devcontainers/java:1-21-bookworm"
    default_post_create="if [ -f pom.xml ]; then mvn install -DskipTests -q; elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then gradle dependencies -q; fi"
    default_extensions=(
      "vscjava.vscode-java-pack"
    )
    ;;
  dotnet)
    base_image="mcr.microsoft.com/devcontainers/dotnet:1-8.0-bookworm"
    default_post_create="dotnet restore || true"
    default_extensions=(
      "ms-dotnettools.csharp"
    )
    ;;
  php)
    base_image="mcr.microsoft.com/devcontainers/php:1-8.3-bookworm"
    default_post_create="if [ -f composer.json ]; then composer install --no-interaction; fi"
    default_extensions=(
      "bmewburn.vscode-intelephense-client"
    )
    ;;
  ruby)
    base_image="mcr.microsoft.com/devcontainers/ruby:1-3.3-bookworm"
    default_post_create="if [ -f Gemfile ]; then bundle install; fi"
    default_extensions=(
      "shopify.ruby-extensions-pack"
    )
    ;;
  swift)
    # No MS devcontainer image for Swift; use the official swift image.
    base_image="swift:5.10"
    default_post_create="if [ -f Package.swift ]; then swift package resolve; fi"
    default_extensions=(
      "sswg.swift-lang"
    )
    ;;
  elixir)
    # No MS devcontainer image for Elixir; use the official elixir image.
    base_image="elixir:1.16"
    default_post_create="if [ -f mix.exs ]; then mix deps.get; fi"
    default_extensions=(
      "jakebecker.elixir-ls"
    )
    ;;
  cpp)
    base_image="mcr.microsoft.com/devcontainers/cpp:1-debian-12"
    default_post_create="if [ -f CMakeLists.txt ]; then cmake -B build -S .; fi"
    default_extensions=(
      "ms-vscode.cpptools-extension-pack"
    )
    ;;
esac

# --- pick name ---------------------------------------------------------------
# When --name isn't supplied, derive from --target basename if available,
# otherwise fall back to a stack-named default. Both Codespaces and
# 'Reopen in Container' surface this string.

if [[ -z "$name" ]]; then
  if [[ -n "$target" ]]; then
    name="$(basename "$target")"
  else
    name="${language}-devcontainer"
  fi
fi

# --- assemble JSON ----------------------------------------------------------
# Use jq -n so we get well-formed JSON regardless of free-form input
# in --name / --post-create-command / extra arrays. No hand-quoting.

post_create_effective="$default_post_create"
if $post_create_command_set; then
  post_create_effective="$post_create_command_override"
fi

# Pull together the extension list: per-language defaults + shared
# baselines (git tooling) + user-supplied. Deduplicate at the end.
shared_extensions=(
  "eamodio.gitlens"
  "mhutchie.git-graph"
)
all_extensions=("${default_extensions[@]}" "${shared_extensions[@]}" "${extra_extensions[@]+"${extra_extensions[@]}"}")

# Shared `features` set — gh CLI + git-lfs + common-utils. Version-
# pinned to a major; floating tags re-broadcast quietly otherwise.
shared_features=(
  "ghcr.io/devcontainers/features/github-cli:1"
  "ghcr.io/devcontainers/features/git-lfs:1"
  "ghcr.io/devcontainers/features/common-utils:2"
)
all_features=("${shared_features[@]}" "${extra_features[@]+"${extra_features[@]}"}")

# Convert arrays to JSON arrays. Dedup preserves first-occurrence order
# (per-language defaults → shared baseline → user-supplied) so the
# rendered list matches the SKILL.md's documented ordering. Earlier
# `jq -s 'unique'` sorted alphabetically, which made diffs noisier and
# contradicted the doc. `awk '!seen[$0]++'` is the standard
# order-preserving dedup primitive in shell.
extensions_json=$(printf '%s\n' "${all_extensions[@]}" \
  | awk '!seen[$0]++' \
  | jq -R . | jq -s .)
features_obj=$(jq -n --args '[$ARGS.positional[]] | map({ (.): {} }) | add // {}' \
  -- "${all_features[@]}")
ports_json="[]"
if [[ ${#extra_ports[@]} -gt 0 ]]; then
  ports_json=$(printf '%s\n' "${extra_ports[@]}" | jq -R 'tonumber' | jq -s .)
fi

# hostRequirements: only include keys the operator actually set so the
# emitted file stays minimal (a blank `hostRequirements: {}` is valid
# but noise on PR review).
hostreq_json="{}"
if [[ -n "$cpus" || -n "$memory" || -n "$storage" ]]; then
  hostreq_json=$(jq -n \
    --arg cpus "$cpus" --arg memory "$memory" --arg storage "$storage" \
    '
    {} +
    (if $cpus    != "" then { cpus:    ($cpus | tonumber) } else {} end) +
    (if $memory  != "" then { memory:  $memory }           else {} end) +
    (if $storage != "" then { storage: $storage }          else {} end)
    ')
fi

rendered=$(jq -n \
  --arg version "$nyann_version" \
  --arg name "$name" \
  --arg image "$base_image" \
  --arg post_create "$post_create_effective" \
  --argjson extensions "$extensions_json" \
  --argjson features "$features_obj" \
  --argjson ports "$ports_json" \
  --argjson hostreq "$hostreq_json" \
  '
  ({
    "$schema": "https://raw.githubusercontent.com/devcontainers/spec/main/schemas/devContainer.schema.json",
    "$comment": (
      "Generated by nyann " + $version + " (gen-devcontainer.sh). " +
      "Re-run the generator to refresh; edits here will diff against " +
      "the template on the next preview pass."
    ),
    name: $name,
    image: $image,
    features: $features,
    customizations: {
      vscode: {
        extensions: $extensions
      }
    }
  })
  + (if ($post_create | length) > 0 then { postCreateCommand: $post_create } else {} end)
  + (if ($ports | length) > 0 then { forwardPorts: $ports } else {} end)
  + (if ($hostreq | keys | length) > 0 then { hostRequirements: $hostreq } else {} end)
  ')

# --- preview vs. apply -------------------------------------------------------

if ! $apply; then
  printf '%s\n' "$rendered"
  exit 0
fi

dest="$target/.devcontainer/devcontainer.json"

# Reject symlink-as-destination, matching gen-dependency-updater and
# the rest of nyann's scaffold scripts. A symlinked devcontainer.json
# pointing outside the repo could redirect generated content.
if [[ -L "$dest" ]]; then
  nyann::die "refusing to write through a symlink: $dest"
fi

# Symlink-mediated escape guard: `mkdir -p` happily follows symlinks
# at intermediate components, so the leaf-only check above can't catch
# a pre-placed `$target/.devcontainer → /etc/` symlink. Walk the
# ancestry explicitly via the shared helper from _lib.sh.
if ! nyann::safe_mkdir_under_target "$target" ".devcontainer" >/dev/null; then
  nyann::die "refusing to write $dest: ancestor is a symlink or mkdir failed"
fi

if [[ -f "$dest" ]]; then
  existing="$(cat "$dest")"
  if [[ "$existing" == "$rendered" ]]; then
    nyann::log "unchanged: $dest already matches the generated config"
    exit 0
  fi

  {
    printf 'gen-devcontainer: existing file differs from generated output:\n'
    diff -u <(printf '%s\n' "$existing") <(printf '%s\n' "$rendered") || true
  } >&2

  if ! $force_overwrite; then
    nyann::warn "$dest exists and differs; re-run with --force-overwrite to replace"
    exit 3
  fi
fi

printf '%s\n' "$rendered" > "$dest"
nyann::log "wrote $dest (language=$language, base=$base_image)"
