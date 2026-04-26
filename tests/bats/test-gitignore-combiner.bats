#!/usr/bin/env bats
# bin/gitignore-combiner.sh — merge nyann gitignore templates into a target
# without clobbering the user's existing entries. This is the canonical
# "merge, never overwrite" path for the .gitignore extras flow; a
# regression here silently destroys user content, so direct coverage
# guards every guarantee (idempotency, dedup, marker headers,
# trailing-newline normalisation, symlink refusal).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMBINER="${REPO_ROOT}/bin/gitignore-combiner.sh"
  TMPL_ROOT="${REPO_ROOT}/templates/gitignore"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# ---- guards -----------------------------------------------------------------

@test "missing --target dies" {
  run bash "$COMBINER" --templates generic
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq -- "--target is required"
}

@test "missing --templates dies" {
  run bash "$COMBINER" --target "$TMP/.gitignore"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq -- "--templates is required"
}

@test "unknown template dies with the path that wasn't found" {
  run bash "$COMBINER" --target "$TMP/.gitignore" --templates this-template-does-not-exist
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "template not found"
}

@test "rejects symlinked --target" {
  real="$TMP/real.txt"
  ln="$TMP/.gitignore"
  : > "$real"
  ln -s "$real" "$ln"
  run bash "$COMBINER" --target "$ln" --templates generic
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "refusing to combine gitignore into a symlink"
}

# ---- create + merge ---------------------------------------------------------

@test "creates the target when it does not exist" {
  target="$TMP/.gitignore"
  [ ! -f "$target" ]
  run bash "$COMBINER" --target "$target" --templates generic
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  # Should have content from the generic template.
  [ -s "$target" ]
}

@test "preserves existing user entries verbatim (merge, never overwrite)" {
  target="$TMP/.gitignore"
  cat > "$target" <<EOF
# my own custom rule
my-secret-dir/
unique-user-pattern.txt
EOF
  user_sha=$(shasum -a 256 < "$target" | awk '{print $1}')

  bash "$COMBINER" --target "$target" --templates generic >/dev/null 2>&1

  # Every original line must still be present (verbatim).
  grep -Fxq "# my own custom rule" "$target"
  grep -Fxq "my-secret-dir/" "$target"
  grep -Fxq "unique-user-pattern.txt" "$target"

  # And the file is now larger than the original (template entries added).
  new_size=$(wc -c < "$target")
  orig_size=${#user_sha}  # not directly comparable — use line count instead
  [ "$(wc -l < "$target")" -gt 3 ]
}

@test "is idempotent: second run is a no-op" {
  target="$TMP/.gitignore"
  bash "$COMBINER" --target "$target" --templates jsts >/dev/null 2>&1
  sha1=$(shasum -a 256 "$target" | awk '{print $1}')

  bash "$COMBINER" --target "$target" --templates jsts >/dev/null 2>&1
  sha2=$(shasum -a 256 "$target" | awk '{print $1}')

  [ "$sha1" = "$sha2" ]
}

@test "deduplicates patterns shared across templates" {
  target="$TMP/.gitignore"
  # Both jsts and python ship `.DS_Store`. After combining both, it should
  # appear at most once (the seed/seen-set dedupes across templates).
  bash "$COMBINER" --target "$target" --templates jsts,python >/dev/null 2>&1
  count=$(grep -Fxc ".DS_Store" "$target" 2>/dev/null || echo 0)
  [ "$count" -le 1 ]
}

@test "skips entries already present in the user's file" {
  target="$TMP/.gitignore"
  echo "node_modules/" > "$target"
  bash "$COMBINER" --target "$target" --templates jsts >/dev/null 2>&1
  # node_modules/ should appear exactly once, not duplicated by the
  # template's identical entry.
  count=$(grep -Fxc "node_modules/" "$target")
  [ "$count" = "1" ]
}

@test "ensures target file ends with a newline before appending" {
  target="$TMP/.gitignore"
  # Write a file with NO trailing newline, then combine. The combiner
  # should normalise so its appended block doesn't smash into the last
  # user line.
  printf "user-rule" > "$target"
  bash "$COMBINER" --target "$target" --templates generic >/dev/null 2>&1
  # First line should still be the user's rule on its own line.
  head -1 "$target" | grep -Fxq "user-rule"
}

@test "writes a marker comment header per appended template" {
  target="$TMP/.gitignore"
  bash "$COMBINER" --target "$target" --templates generic,jsts >/dev/null 2>&1
  grep -Fq "# --- nyann: generic ---" "$target"
  grep -Fq "# --- nyann: jsts ---" "$target"
}
