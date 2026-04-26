#!/usr/bin/env bats
# bin/gen-claudemd.sh — EXIT trap ensures $tmp / $block_file / $merged
# are cleaned up even when the script exits non-zero.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-claudemd.sh"
  TMP=$(mktemp -d -t nyann-gentrap.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"

  PROFILE="$TMP/profile.json"
  cp "${REPO_ROOT}/profiles/default.json" "$PROFILE"
  DOC_PLAN="$TMP/doc-plan.json"
  cat > "$DOC_PLAN" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {},
  "claude_md_mode": "router",
  "size_budget_kb": 3
}
JSON

  # Isolate /tmp so the test can count nyann leftovers without false
  # positives from other tests.
  ISOLATED_TMP="$TMP/isolated-tmp"
  mkdir -p "$ISOLATED_TMP"
}

teardown() { rm -rf "$TMP"; }

count_orphans() {
  # Look for any leftover nyann-claude.* / nyann-block.* / nyann-claude-merged.*
  # under the isolated TMPDIR. Using `find` instead of globs because
  # absent matches should yield 0, not a shell error.
  find "$ISOLATED_TMP" -maxdepth 1 -type f \( \
    -name 'nyann-claude.*' -o \
    -name 'nyann-block.*' -o \
    -name 'nyann-claude-merged.*' \
  \) 2>/dev/null | wc -l | tr -d ' '
}

@test "replace-markers path exits non-zero over hard-cap → no temp files leaked" {
  # Pre-seed CLAUDE.md with markers + content that pushes the merged
  # file past the 8192 B hard cap. gen-claudemd dies on check_size
  # *after* creating $tmp and $block_file; without the trap, both leak.
  python3 -c "print('x' * 7900, end='')" > "$REPO/CLAUDE.md.head"
  cat > "$REPO/CLAUDE.md" <<'MD'
<!-- nyann:start -->
old
<!-- nyann:end -->
MD
  cat "$REPO/CLAUDE.md.head" >> "$REPO/CLAUDE.md"
  rm "$REPO/CLAUDE.md.head"

  before=$(count_orphans)
  run env TMPDIR="$ISOLATED_TMP" bash "$GEN" \
    --profile "$PROFILE" --doc-plan "$DOC_PLAN" --target "$REPO"
  [ "$status" -ne 0 ]
  # File must not have been overwritten.
  grep -Fq "old" "$REPO/CLAUDE.md"
  # And — the whole point of this test — no orphans.
  after=$(count_orphans)
  [ "$before" = "$after" ]
}

@test "append path exits non-zero over hard-cap → no \$merged leaked" {
  # Existing CLAUDE.md without markers + big enough to push the merged
  # file past the hard cap. Forces the append branch to die in
  # check_size *after* $merged is created.
  python3 -c "print('x' * 8100, end='')" > "$REPO/CLAUDE.md"

  before=$(count_orphans)
  run env TMPDIR="$ISOLATED_TMP" bash "$GEN" \
    --profile "$PROFILE" --doc-plan "$DOC_PLAN" --target "$REPO"
  [ "$status" -ne 0 ]
  # File unchanged.
  [ "$(wc -c < "$REPO/CLAUDE.md")" -eq 8100 ]
  after=$(count_orphans)
  [ "$before" = "$after" ]
}

@test "successful runs still clean up their temp files" {
  before=$(count_orphans)
  run env TMPDIR="$ISOLATED_TMP" bash "$GEN" \
    --profile "$PROFILE" --doc-plan "$DOC_PLAN" --target "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$REPO/CLAUDE.md" ]
  after=$(count_orphans)
  [ "$before" = "$after" ]
}
