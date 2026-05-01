#!/usr/bin/env bats
# bin/suggest-profile.sh — profile suggestion tests.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUGGEST="${REPO_ROOT}/bin/suggest-profile.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# --- basic functionality ---

@test "produces valid JSON output" {
  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e . "$TMP/out.json" >/dev/null
}

@test "detected block has language field" {
  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  [ "$(jq -r '.detected.language' "$TMP/out.json")" != "null" ]
}

@test "suggestions is an array" {
  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.suggestions | type == "array"' "$TMP/out.json" >/dev/null
}

# --- TypeScript detection ---

@test "TypeScript repo suggests typescript profiles" {
  mkdir -p "$TMP/ts-repo"
  echo '{"name":"test","dependencies":{"typescript":"^5.0"}}' > "$TMP/ts-repo/package.json"
  echo '{}' > "$TMP/ts-repo/tsconfig.json"
  touch "$TMP/ts-repo/index.ts"

  bash "$SUGGEST" --target "$TMP/ts-repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  top=$(jq -r '.suggestions[0].name' "$TMP/out.json")
  # Should suggest a typescript-related profile.
  jq -e '.suggestions | length > 0' "$TMP/out.json" >/dev/null
  jq -e '.suggestions | map(.name) | any(test("typescript|nextjs|react|node"))' "$TMP/out.json" >/dev/null
}

@test "Next.js repo suggests nextjs-prototype" {
  mkdir -p "$TMP/next-repo"
  echo '{"name":"test","dependencies":{"next":"^14.0","react":"^18.0","typescript":"^5.0"}}' > "$TMP/next-repo/package.json"
  echo '{}' > "$TMP/next-repo/tsconfig.json"
  mkdir -p "$TMP/next-repo/app"
  touch "$TMP/next-repo/app/page.tsx"

  bash "$SUGGEST" --target "$TMP/next-repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  top=$(jq -r '.suggestions[0].name' "$TMP/out.json")
  [ "$top" = "nextjs-prototype" ]
}

# --- Python detection ---

@test "Python + FastAPI suggests fastapi-service first" {
  mkdir -p "$TMP/py-repo"
  cat > "$TMP/py-repo/pyproject.toml" <<'TOML'
[project]
name = "test"
dependencies = ["fastapi"]
TOML
  touch "$TMP/py-repo/main.py"

  bash "$SUGGEST" --target "$TMP/py-repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  top=$(jq -r '.suggestions[0].name' "$TMP/out.json")
  [ "$top" = "fastapi-service" ]
}

@test "bare Python repo suggests python-cli" {
  mkdir -p "$TMP/py-bare"
  cat > "$TMP/py-bare/pyproject.toml" <<'TOML'
[project]
name = "test"
TOML
  touch "$TMP/py-bare/main.py"

  bash "$SUGGEST" --target "$TMP/py-bare" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  # python-cli should appear in suggestions (language match, no framework).
  jq -e '.suggestions | map(.name) | any(. == "python-cli")' "$TMP/out.json" >/dev/null
}

# --- Go detection ---

@test "Go repo suggests go-service" {
  mkdir -p "$TMP/go-repo"
  echo 'module example.com/test' > "$TMP/go-repo/go.mod"
  touch "$TMP/go-repo/main.go"

  bash "$SUGGEST" --target "$TMP/go-repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  top=$(jq -r '.suggestions[0].name' "$TMP/out.json")
  [ "$top" = "go-service" ]
}

# --- Rust detection ---

@test "Rust repo suggests rust-cli" {
  mkdir -p "$TMP/rust-repo/src"
  cat > "$TMP/rust-repo/Cargo.toml" <<'TOML'
[package]
name = "test"
version = "0.1.0"
TOML
  touch "$TMP/rust-repo/src/main.rs"

  bash "$SUGGEST" --target "$TMP/rust-repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  top=$(jq -r '.suggestions[0].name' "$TMP/out.json")
  [ "$top" = "rust-cli" ]
}

# --- sorting ---

@test "suggestions are sorted by confidence descending" {
  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  count=$(jq '.suggestions | length' "$TMP/out.json")
  if (( count >= 2 )); then
    jq -e '.suggestions | [.[:-1], .[1:]] | transpose | all(.[0].confidence >= .[1].confidence)' "$TMP/out.json" >/dev/null
  fi
}

# --- multi-stack ---

@test "secondary_suggestions is present in output" {
  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.secondary_suggestions | type == "array"' "$TMP/out.json" >/dev/null
}

@test "multi-stack repo produces secondary suggestions" {
  mkdir -p "$TMP/multi"
  # Primary: TypeScript (Next.js)
  echo '{"name":"test","dependencies":{"next":"^14.0","react":"^18.0","typescript":"^5.0"}}' > "$TMP/multi/package.json"
  echo '{}' > "$TMP/multi/tsconfig.json"
  mkdir -p "$TMP/multi/app"
  touch "$TMP/multi/app/page.tsx"
  # Secondary: Python
  cat > "$TMP/multi/pyproject.toml" <<'TOML'
[project]
name = "backend"
dependencies = ["fastapi"]
TOML
  touch "$TMP/multi/main.py"

  bash "$SUGGEST" --target "$TMP/multi" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  # Primary should be typescript/next.
  [ "$(jq -r '.suggestions[0].name' "$TMP/out.json")" = "nextjs-prototype" ]
  # Secondary should contain python suggestions.
  jq -e '.secondary_suggestions | length > 0' "$TMP/out.json" >/dev/null
  jq -e '.secondary_suggestions | map(.language) | any(. == "python")' "$TMP/out.json" >/dev/null
  jq -e '.secondary_suggestions[] | select(.language == "python") | .suggestions | map(.name) | any(test("python|fastapi|django"))' "$TMP/out.json" >/dev/null
}

@test "three-language repo produces multiple secondary suggestions" {
  mkdir -p "$TMP/triple/src"
  # Primary: TypeScript
  echo '{"name":"test","dependencies":{"typescript":"^5.0"}}' > "$TMP/triple/package.json"
  echo '{}' > "$TMP/triple/tsconfig.json"
  touch "$TMP/triple/index.ts"
  # Secondary 1: Python
  cat > "$TMP/triple/pyproject.toml" <<'TOML'
[project]
name = "backend"
TOML
  touch "$TMP/triple/main.py"
  # Secondary 2: Go
  echo 'module example.com/test' > "$TMP/triple/go.mod"
  touch "$TMP/triple/cmd.go"

  bash "$SUGGEST" --target "$TMP/triple" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  # Should have at least 2 secondary suggestion groups.
  sec_count=$(jq '.secondary_suggestions | length' "$TMP/out.json")
  [ "$sec_count" -ge 2 ]
  # Both python and go should appear.
  jq -e '.secondary_suggestions | map(.language) | any(. == "python")' "$TMP/out.json" >/dev/null
  jq -e '.secondary_suggestions | map(.language) | any(. == "go")' "$TMP/out.json" >/dev/null
  # Each secondary group should have suggestions.
  jq -e '.secondary_suggestions | all(.suggestions | length > 0)' "$TMP/out.json" >/dev/null
}

@test "detected block includes secondary_languages and is_monorepo" {
  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.detected.secondary_languages | type == "array"' "$TMP/out.json" >/dev/null
  jq -e '.detected | has("is_monorepo")' "$TMP/out.json" >/dev/null
}

# --- empty repo ---

@test "empty repo returns suggestions (at least default-like match)" {
  mkdir -p "$TMP/empty"
  bash "$SUGGEST" --target "$TMP/empty" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  jq -e '.suggestions | type == "array"' "$TMP/out.json" >/dev/null
}

# --- error cases ---

@test "missing target dies" {
  run bash "$SUGGEST" --target "$TMP/nonexistent"
  [ "$status" -ne 0 ]
}

# --- schema validation ---

@test "output validates against profile-suggestion schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi

  mkdir -p "$TMP/repo"
  bash "$SUGGEST" --target "$TMP/repo" --plugin-root "$REPO_ROOT" > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/profile-suggestion.schema.json" "$TMP/out.json"
}
