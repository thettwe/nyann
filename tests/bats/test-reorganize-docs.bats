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

@test "leading-dash path is treated as an operand, not a git mv option (BUG F)" {
  # BUG F: `git mv "$source" "$target"` without `--` lets a path beginning
  # with `-` be parsed as an option (option injection). The `--` terminator
  # forces both operands to be paths. A confined-under-target file named
  # `-rf.md` must move cleanly rather than being mis-parsed as a flag.
  git -C "$TARGET" init -q
  git -C "$TARGET" config user.email t@e.com
  git -C "$TARGET" config user.name t
  printf 'dash content\n' > "$TARGET/-rf.md"
  git -C "$TARGET" add -- "-rf.md"
  git -C "$TARGET" commit -qm init
  write_moves '[{"source":"-rf.md","target":"docs/architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "moved:"
  [ -f "$TARGET/docs/architecture.md" ]
  [ "$(cat "$TARGET/docs/architecture.md")" = "dash content" ]
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

# ---- BUG D: case-only rename on a case-insensitive FS ----------------------
# `[[ -e "$target_abs" ]]` refused the move when the destination "exists".
# On a case-insensitive filesystem (macOS default) a case-only rename
# (`ARCHITECTURE.md` → `architecture.md`) sees the destination as the very
# same inode, so the conformance feature silently no-op'd on the
# maintainer's platform. The fix detects a same-inode source/target and
# routes it through a two-step (`git mv`/`mv` via a temp name) rename. On a
# case-sensitive FS the two names are distinct files and this is a normal
# move — either way the lowercase target must end up holding the content.

@test "case-only rename (ARCHITECTURE.md → architecture.md) succeeds, not skipped (non-git)" {
  printf 'arch content\n' > "$TARGET/ARCHITECTURE.md"
  write_moves '[{"source":"ARCHITECTURE.md","target":"architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "moved:"
  # The lowercase name now holds the content.
  [ -f "$TARGET/architecture.md" ]
  [ "$(cat "$TARGET/architecture.md")" = "arch content" ]
  # No leftover temp file from the two-step rename.
  ! ls "$TARGET"/.nyann-caserename.* >/dev/null 2>&1
  # On a case-insensitive FS only one name resolves; assert the uppercase
  # name no longer resolves to the OLD content (it's been renamed).
  if [ -f "$TARGET/ARCHITECTURE.md" ]; then
    # case-insensitive FS: same inode, content is the moved content.
    [ "$(cat "$TARGET/ARCHITECTURE.md")" = "arch content" ]
  fi
}

@test "case-only rename inside a git repo succeeds" {
  git -C "$TARGET" init -q
  git -C "$TARGET" config user.email t@e.com
  git -C "$TARGET" config user.name t
  printf 'arch content\n' > "$TARGET/ARCHITECTURE.md"
  git -C "$TARGET" add ARCHITECTURE.md
  git -C "$TARGET" commit -qm init
  write_moves '[{"source":"ARCHITECTURE.md","target":"architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "moved:"
  [ "$(cat "$TARGET/architecture.md")" = "arch content" ]
  ! ls "$TARGET"/.nyann-caserename.* >/dev/null 2>&1
  # Git tracks the file under the new casing.
  git -C "$TARGET" ls-files | grep -qx "architecture.md"
}

@test "genuine different-file destination is still refused (case-only fix doesn't clobber)" {
  printf 'new\n' > "$TARGET/ARCHITECTURE.md"
  mkdir -p "$TARGET/docs"
  printf 'existing-different\n' > "$TARGET/docs/architecture.md"
  write_moves '[{"source":"ARCHITECTURE.md","target":"docs/architecture.md","category":"architecture","confidence":0.95,"reason":"r"}]'
  run bash "${REPO_ROOT}/bin/reorganize-docs.sh" --target "$TARGET" --moves "$TMP/moves.json" --apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "target already exists"
  # The genuinely different destination file is untouched.
  [ "$(cat "$TARGET/docs/architecture.md")" = "existing-different" ]
}
