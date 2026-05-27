#!/usr/bin/env bats
# bin/gen-devcontainer.sh — devcontainer.json generation, preview-
# then-apply, idempotency, per-language defaults.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-devcontainer.sh"
  SCHEMA="${REPO_ROOT}/schemas/devcontainer-config.schema.json"
  TMP=$(mktemp -d)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Helpers --------------------------------------------------------------------

json_valid() {
  python3 -c "import sys, json; json.load(open(sys.argv[1]))" "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "rejects missing --language" {
  run bash "$GEN"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF -- "language"
}

@test "rejects unknown language" {
  run bash "$GEN" --language haskell
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF -- "language"
}

@test "rejects out-of-range --port" {
  run bash "$GEN" --language node --port 99999
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "1-65535"
}

@test "rejects malformed --extension id" {
  run bash "$GEN" --language node --extension "not-a-publisher-format"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "publisher.extension"
}

@test "rejects --cpus out of 2..32" {
  run bash "$GEN" --language node --cpus 1
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "2-32"
  run bash "$GEN" --language node --cpus 64
  [ "$status" -ne 0 ]
}

@test "rejects malformed --memory" {
  run bash "$GEN" --language node --memory "4 gigs"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "gb"
}

# ---------------------------------------------------------------------------
# Per-language rendering — pinned base image + extension baseline
# ---------------------------------------------------------------------------

@test "node language emits npm/eslint baseline + javascript-node image" {
  bash "$GEN" --language node > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.image | test("javascript-node")' "$TMP/out.json" >/dev/null
  jq -e '.customizations.vscode.extensions | contains(["dbaeumer.vscode-eslint"])' "$TMP/out.json" >/dev/null
  jq -e '.postCreateCommand | test("npm ci")' "$TMP/out.json" >/dev/null
}

@test "python language emits python image + ruff extension" {
  bash "$GEN" --language python > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.image | test("python")' "$TMP/out.json" >/dev/null
  jq -e '.customizations.vscode.extensions | contains(["charliermarsh.ruff"])' "$TMP/out.json" >/dev/null
}

@test "every supported language renders valid JSON with image + extensions" {
  # Iterate the schema's enum so any future addition is auto-covered.
  while IFS= read -r lang; do
    bash "$GEN" --language "$lang" > "$TMP/out.json" \
      || { echo "$lang failed to render" >&2; return 1; }
    json_valid "$TMP/out.json" \
      || { echo "$lang produced invalid JSON" >&2; return 1; }
    jq -e '.image | length > 0' "$TMP/out.json" >/dev/null \
      || { echo "$lang missing image field" >&2; return 1; }
    jq -e '.customizations.vscode.extensions | length > 0' "$TMP/out.json" >/dev/null \
      || { echo "$lang missing extensions" >&2; return 1; }
    # Shared baseline — gitlens + git-graph always present.
    jq -e '.customizations.vscode.extensions | contains(["eamodio.gitlens","mhutchie.git-graph"])' "$TMP/out.json" >/dev/null \
      || { echo "$lang missing shared git tooling extensions" >&2; return 1; }
    # Shared features — gh + git-lfs + common-utils always present.
    jq -e '.features | has("ghcr.io/devcontainers/features/github-cli:1") and has("ghcr.io/devcontainers/features/git-lfs:1") and has("ghcr.io/devcontainers/features/common-utils:2")' "$TMP/out.json" >/dev/null \
      || { echo "$lang missing shared features" >&2; return 1; }
  done < <(jq -r '.properties.language.enum[]' "$SCHEMA")
}

# ---------------------------------------------------------------------------
# Optional flags
# ---------------------------------------------------------------------------

@test "--port adds forwardPorts entries" {
  bash "$GEN" --language node --port 3000 --port 5173 > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.forwardPorts | contains([3000, 5173])' "$TMP/out.json" >/dev/null
}

@test "--cpus / --memory / --storage populate hostRequirements" {
  bash "$GEN" --language node --cpus 4 --memory 8gb --storage 32gb > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.hostRequirements.cpus == 4' "$TMP/out.json" >/dev/null
  jq -e '.hostRequirements.memory == "8gb"' "$TMP/out.json" >/dev/null
  jq -e '.hostRequirements.storage == "32gb"' "$TMP/out.json" >/dev/null
}

@test "hostRequirements omitted when no resource flags supplied" {
  bash "$GEN" --language node > "$TMP/out.json"
  ! jq -e 'has("hostRequirements")' "$TMP/out.json" >/dev/null
}

@test "--extension merges onto per-language defaults (no duplicates)" {
  bash "$GEN" --language node --extension "dbaeumer.vscode-eslint" --extension "ms-azuretools.vscode-docker" > "$TMP/out.json"
  json_valid "$TMP/out.json"
  # eslint appeared twice on input; dedup keeps it once.
  count=$(jq -r '.customizations.vscode.extensions | map(select(. == "dbaeumer.vscode-eslint")) | length' "$TMP/out.json")
  [ "$count" -eq 1 ]
  # extra extension is present
  jq -e '.customizations.vscode.extensions | contains(["ms-azuretools.vscode-docker"])' "$TMP/out.json" >/dev/null
}

@test "--feature merges onto shared baseline" {
  bash "$GEN" --language python --feature "ghcr.io/devcontainers/features/docker-in-docker:2" > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.features | has("ghcr.io/devcontainers/features/docker-in-docker:2")' "$TMP/out.json" >/dev/null
  # Shared baseline still present.
  jq -e '.features | has("ghcr.io/devcontainers/features/github-cli:1")' "$TMP/out.json" >/dev/null
}

@test "--post-create-command overrides the per-language default" {
  bash "$GEN" --language node --post-create-command "pnpm install --frozen-lockfile" > "$TMP/out.json"
  jq -e '.postCreateCommand == "pnpm install --frozen-lockfile"' "$TMP/out.json" >/dev/null
}

@test "empty --post-create-command suppresses the postCreateCommand field" {
  bash "$GEN" --language node --post-create-command "" > "$TMP/out.json"
  ! jq -e 'has("postCreateCommand")' "$TMP/out.json" >/dev/null
}

@test "--name overrides the default display name" {
  bash "$GEN" --language node --name "my-cool-app" > "$TMP/out.json"
  jq -e '.name == "my-cool-app"' "$TMP/out.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Apply mode
# ---------------------------------------------------------------------------

@test "preview does not write to the filesystem" {
  bash "$GEN" --language node --target "$TMP" >/dev/null
  [ ! -e "$TMP/.devcontainer/devcontainer.json" ]
}

@test "apply writes .devcontainer/devcontainer.json" {
  bash "$GEN" --language node --target "$TMP" --apply >/dev/null
  [ -f "$TMP/.devcontainer/devcontainer.json" ]
  json_valid "$TMP/.devcontainer/devcontainer.json"
}

@test "apply derives default name from target basename" {
  mkdir -p "$TMP/my-app"
  bash "$GEN" --language node --target "$TMP/my-app" --apply >/dev/null
  jq -e '.name == "my-app"' "$TMP/my-app/.devcontainer/devcontainer.json" >/dev/null
}

@test "apply refuses to write through a symlink destination" {
  mkdir -p "$TMP/.devcontainer"
  ln -s "/etc/decoy-target" "$TMP/.devcontainer/devcontainer.json"
  run bash "$GEN" --language node --target "$TMP" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "symlink"
  [ ! -f "/etc/decoy-target" ]
}

@test "apply refuses when .devcontainer ancestor is itself a symlink" {
  # Same H1 escape vector as the dependabot path: a pre-existing
  # symlink at `<target>/.devcontainer → decoy` would cause `mkdir -p`
  # to follow the link and write devcontainer.json into the decoy.
  # The shared safe_mkdir_under_target helper must catch this before
  # any write happens.
  decoy="$TMP/decoy-devc"
  mkdir -p "$decoy"
  ln -s "$decoy" "$TMP/.devcontainer"

  run bash "$GEN" --language node --target "$TMP" --apply
  [ "$status" -ne 0 ]
  [ ! -f "$decoy/devcontainer.json" ]
}

@test "apply rejects nonexistent --target" {
  run bash "$GEN" --language node --target "$TMP/missing" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "directory"
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "rerun with identical inputs is a no-op (exit 0, 'unchanged' log)" {
  bash "$GEN" --language node --target "$TMP" --apply >/dev/null
  run bash "$GEN" --language node --target "$TMP" --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "unchanged"
}

@test "diverged file: refuses overwrite without --force-overwrite (exit 3)" {
  mkdir -p "$TMP/.devcontainer"
  printf '{"name":"existing"}\n' > "$TMP/.devcontainer/devcontainer.json"
  run bash "$GEN" --language node --target "$TMP" --apply
  [ "$status" -eq 3 ]
  echo "$output" | grep -qF "differs"
  grep -qF '"name":"existing"' "$TMP/.devcontainer/devcontainer.json"
}

@test "diverged file: --force-overwrite replaces it" {
  mkdir -p "$TMP/.devcontainer"
  printf '{"name":"existing"}\n' > "$TMP/.devcontainer/devcontainer.json"
  run bash "$GEN" --language node --target "$TMP" --apply --force-overwrite
  [ "$status" -eq 0 ]
  json_valid "$TMP/.devcontainer/devcontainer.json"
  ! grep -qF '"name":"existing"' "$TMP/.devcontainer/devcontainer.json"
}

# ---------------------------------------------------------------------------
# Schema sanity (hand-rolled input vs. our DevcontainerConfig)
# ---------------------------------------------------------------------------

@test "devcontainer-config schema: a minimal valid input passes" {
  cat > "$TMP/in.json" <<'EOF'
{ "language": "node" }
EOF
  uvx --quiet check-jsonschema --schemafile "$SCHEMA" "$TMP/in.json" 2>&1
}

@test "devcontainer-config schema: rejects unknown language" {
  cat > "$TMP/in.json" <<'EOF'
{ "language": "fortran" }
EOF
  ! uvx --quiet check-jsonschema --schemafile "$SCHEMA" "$TMP/in.json" 2>&1
}
