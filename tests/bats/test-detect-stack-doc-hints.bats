#!/usr/bin/env bats
# v1.9.0: detect-stack.sh::detect_doc_hints — when no code is present,
# scan README/PRD/tech-stack docs to infer primary_language and framework.
# Only fires when primary_language detection already returned "unknown".

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
}

teardown() { rm -rf "$TMP"; }

@test "README mentioning FastAPI: hints python (language detection)" {
  # Note: framework detection from doc hints requires gawk's \b word
  # boundary support (BSD/macOS awk treats \b literally). The language
  # detector uses simpler alternation regexes that work on both awks.
  cat > "$TARGET/README.md" <<'EOF'
# My API

This service uses FastAPI for the HTTP layer.
Built with Python 3.12 and async patterns.
EOF
  result=$(bash "$DETECT" --path "$TARGET" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.primary_language')" = "python" ]
}

@test "PRD mentioning Next.js: hints typescript (language detection)" {
  mkdir -p "$TARGET/docs"
  cat > "$TARGET/docs/prd.md" <<'EOF'
# Product Spec

Frontend: TypeScript, Next.js 15 with React Server Components.
Backend: separate service, not in scope.
EOF
  result=$(bash "$DETECT" --path "$TARGET" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.primary_language')" = "typescript" ]
}

@test "tech-stack.md mentioning Rust: hints rust" {
  mkdir -p "$TARGET/docs"
  cat > "$TARGET/docs/tech-stack.md" <<'EOF'
Backend in Rust using Actix and Tokio.
EOF
  result=$(bash "$DETECT" --path "$TARGET" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.primary_language')" = "rust" ]
}

@test "doc hints do NOT override existing code detection" {
  # Repo with both Python files AND a README mentioning Rust — the
  # actual Python signal must win (hints only fire when language is unknown).
  echo "print('hi')" > "$TARGET/main.py"
  cat > "$TARGET/pyproject.toml" <<'EOF'
[project]
name = "real-app"
version = "0.1.0"
EOF
  cat > "$TARGET/README.md" <<'EOF'
# Rust port planned

Eventually we will rewrite this in Rust with Actix.
EOF
  result=$(bash "$DETECT" --path "$TARGET" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.primary_language')" = "python" ]
}

@test "no code AND no doc hints: primary_language stays unknown" {
  echo "# Just a title" > "$TARGET/README.md"
  result=$(bash "$DETECT" --path "$TARGET" 2>/dev/null)
  [ "$(echo "$result" | jq -r '.primary_language')" = "unknown" ]
}
