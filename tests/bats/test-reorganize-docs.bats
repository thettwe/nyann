#!/usr/bin/env bats
# Tests for bin/reorganize-docs.sh — preview-by-default doc reorganizer.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
}

teardown() { rm -rf "$TMP"; }

write_moves() {
  # $1 = JSON content to write
  printf '%s\n' "$1" > "$TMP/moves.json"
}

@test "preview is the default (no --apply, files do not move)" {
  echo "arch content" > "$TARGET/ARCHITECTURE.md"
  write_moves '[{"source":"ARCHITECTURE.md","target":"docs/architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/ARCHITECTURE.md" ]
  [ ! -f "$TARGET/docs/architecture.md" ]
  echo "$output" | grep -q "preview only"
}

@test "--apply executes the move" {
  echo "arch content" > "$TARGET/ARCHITECTURE.md"
  write_moves '[{"source":"ARCHITECTURE.md","target":"docs/architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 0 ]
  [ ! -f "$TARGET/ARCHITECTURE.md" ]
  [ -f "$TARGET/docs/architecture.md" ]
  [ "$(cat "$TARGET/docs/architecture.md")" = "arch content" ]
}

@test "--yes is an alias for --apply" {
  echo "x" > "$TARGET/PRD.md"
  write_moves '[{"source":"PRD.md","target":"docs/prd.md","category":"prd","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --yes
  [ "$status" -eq 0 ]
  [ -f "$TARGET/docs/prd.md" ]
}

@test "idempotent: second --apply run is a clean no-op when source is gone" {
  echo "x" > "$TARGET/ARCHITECTURE.md"
  write_moves '[{"source":"ARCHITECTURE.md","target":"docs/architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  # Source no longer exists → row skipped → exit 2 (partial-failure semantics)
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "source does not exist"
}

@test "refuses to overwrite existing target" {
  echo "old" > "$TARGET/ARCHITECTURE.md"
  mkdir -p "$TARGET/docs"
  echo "existing" > "$TARGET/docs/architecture.md"
  write_moves '[{"source":"ARCHITECTURE.md","target":"docs/architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 2 ]
  [ "$(cat "$TARGET/docs/architecture.md")" = "existing" ]
  echo "$output" | grep -q "target already exists"
}

@test "empty moves array: clean exit, no output churn" {
  write_moves '[]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no moves to execute"
}

@test "malformed moves JSON dies with a clear error" {
  printf 'this is not json\n' > "$TMP/moves.json"
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not valid json"
}

@test "path traversal in source is rejected" {
  mkdir -p "$TMP/outside"
  echo "x" > "$TMP/outside/secrets.md"
  write_moves '[{"source":"../outside/secrets.md","target":"docs/leaked.md","category":"prd","confidence":0.9,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 2 ]
  [ ! -f "$TARGET/docs/leaked.md" ]
  [ -f "$TMP/outside/secrets.md" ]
  echo "$output" | grep -q "unsafe source path"
}

@test "path traversal in target is rejected" {
  echo "x" > "$TARGET/INNOCENT.md"
  write_moves '[{"source":"INNOCENT.md","target":"../escape.md","category":"prd","confidence":0.9,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 2 ]
  [ ! -f "$TMP/escape.md" ]
  [ -f "$TARGET/INNOCENT.md" ]
  echo "$output" | grep -q "unsafe target path"
}

@test "symlink source is rejected" {
  echo "real" > "$TARGET/real.md"
  ln -s real.md "$TARGET/link.md"
  write_moves '[{"source":"link.md","target":"docs/architecture.md","category":"architecture","confidence":0.9,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "source is a symlink"
}

@test "non-git target uses plain mv (no git failure)" {
  # No .git directory
  echo "x" > "$TARGET/ARCH.md"
  write_moves '[{"source":"ARCH.md","target":"docs/architecture.md","category":"architecture","confidence":0.9,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 0 ]
  [ -f "$TARGET/docs/architecture.md" ]
}

@test "non-array moves file (JSON object) is rejected" {
  printf '{"source":"a","target":"b"}\n' > "$TMP/moves.json"
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "must be a JSON array"
}
