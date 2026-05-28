#!/usr/bin/env bats
# bin/commit-hygiene.sh — scope suggestion, incomplete-staging detection,
# debug-artifact scan, dead-code fold-in.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-hyg.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

@test "scope suggestion: single-scope diff yields a primary" {
  mkdir -p "$REPO/src"
  echo a > "$REPO/src/a.ts"
  echo b > "$REPO/src/b.ts"
  ( cd "$REPO" && git add src/. )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  echo "$out" | jq -e '.scope_suggestion.primary == "src"'
  echo "$out" | jq -e '.scope_suggestion.scopes == ["src"]'
}

@test "scope suggestion: multi-scope diff yields null primary" {
  mkdir -p "$REPO/src" "$REPO/docs"
  echo a > "$REPO/src/a.ts"
  echo b > "$REPO/docs/b.md"
  ( cd "$REPO" && git add src/. docs/. )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  echo "$out" | jq -e '.scope_suggestion.primary == null'
  count=$(echo "$out" | jq '.scope_suggestion.scopes | length')
  [ "$count" -eq 2 ]
  echo "$out" | jq -e '.summary.advisories >= 1'
}

@test "incomplete staging: source staged but matching test unstaged" {
  mkdir -p "$REPO/src" "$REPO/tests"
  echo "def f(): pass" > "$REPO/src/foo.py"
  echo "def test_f(): pass" > "$REPO/tests/test_foo.py"
  ( cd "$REPO" && git add src/foo.py tests/test_foo.py \
      && git commit -q -m "feat: initial foo" )
  # Modify both files but stage only the source.
  echo "def f(): return 1" > "$REPO/src/foo.py"
  echo "def test_f(): assert True" > "$REPO/tests/test_foo.py"
  ( cd "$REPO" && git add src/foo.py )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  echo "$out" | jq -e '.incomplete_staging | length >= 1'
}

@test "incomplete staging: package.json staged but lockfile unstaged" {
  echo '{}' > "$REPO/package.json"
  echo '{"lockfileVersion":1}' > "$REPO/package-lock.json"
  ( cd "$REPO" && git add package.json package-lock.json \
      && git commit -q -m "chore: deps" )
  # Modify both, stage only manifest.
  echo '{"name":"x"}' > "$REPO/package.json"
  echo '{"lockfileVersion":1,"x":1}' > "$REPO/package-lock.json"
  ( cd "$REPO" && git add package.json )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  echo "$out" | jq -e '.incomplete_staging[] | select(.staged == "package.json" and .missing == "lockfile")'
}

@test "debug artifacts: console.log in added line is flagged" {
  mkdir -p "$REPO/src"
  echo "export const x = 1;" > "$REPO/src/a.ts"
  ( cd "$REPO" && git add src/a.ts && git commit -q -m "feat: x" )
  cat > "$REPO/src/a.ts" <<'EOF'
export const x = 1;
console.log("debug");
EOF
  ( cd "$REPO" && git add src/a.ts )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  echo "$out" | jq -e '.debug_artifacts | length >= 1'
}

@test "debug artifacts: pre-existing TODO not flagged when unchanged" {
  mkdir -p "$REPO/src"
  printf '%s\n' "// TODO old" "let z = 1;" > "$REPO/src/b.ts"
  ( cd "$REPO" && git add src/b.ts && git commit -q -m "feat: b" )
  # Modify a different line in the file.
  printf '%s\n' "// TODO old" "let z = 2;" > "$REPO/src/b.ts"
  ( cd "$REPO" && git add src/b.ts )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  # No NEW debug artifact added on the changed line.
  count=$(echo "$out" | jq '.debug_artifacts | length')
  [ "$count" -eq 0 ]
}

@test "custom patterns from --patterns override defaults" {
  echo "let x = 1; // BUG: bad" > "$REPO/c.ts"
  ( cd "$REPO" && git add c.ts )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO" --patterns "BUG,HACK")
  echo "$out" | jq -e '.debug_artifacts | length >= 1'
}

@test "clean staged diff: no warnings" {
  echo "let x = 1;" > "$REPO/clean.ts"
  ( cd "$REPO" && git add clean.ts )
  out=$(bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO")
  echo "$out" | jq -e '.summary.warnings == 0'
  echo "$out" | jq -e '.debug_artifacts == []'
}

@test "Output validates against commit-hygiene schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  echo "x" > "$REPO/a.txt"
  ( cd "$REPO" && git add a.txt )
  bash "$REPO_ROOT/bin/commit-hygiene.sh" --target "$REPO" > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/commit-hygiene.schema.json" "$TMP/r.json"
}
