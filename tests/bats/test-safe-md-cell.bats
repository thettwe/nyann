#!/usr/bin/env bats
# bin/_lib.sh — nyann::safe_md_cell escape behaviour.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LIB="${REPO_ROOT}/bin/_lib.sh"
}

sc() {
  bash -c "source '$LIB'; nyann::safe_md_cell \"\$1\"" _ "$1"
}

# Without the leading `&` escape, a value containing a literal HTML
# entity like `&#124;` slipped through unchanged and the markdown
# renderer decoded it back to `|` on display — i.e. the helper claimed
# to prevent cell-boundary breakage but a crafted value still visually
# produced a pipe. The fix escapes `&` → `&amp;` as the first pass so
# entity-shaped inputs render as their literal text.

@test "literal & in input is encoded as &amp;" {
  out=$(sc 'foo & bar')
  [ "$out" = 'foo &amp; bar' ]
}

@test "entity-shaped input &#124; becomes &amp;#124; (renders as text, not pipe)" {
  out=$(sc 'left&#124;right')
  # The key property: the result no longer contains the bare entity
  # `&#124;`. If it did, markdown would decode it back to `|`.
  [ "$out" = 'left&amp;#124;right' ]
  ! echo "$out" | grep -Fq '&#124;right'
}

@test "& escape runs before |/<!--/--> so our own entities aren't double-escaped in one pass" {
  # A single call must NOT produce `&amp;#124;` for a bare `|` — the
  # `|` rule should emit `&#124;` whose `&` is ours, not the user's.
  out=$(sc 'a|b')
  [ "$out" = 'a&#124;b' ]
}

@test "pipe and marker substitutions still fire after the & pass" {
  out=$(sc 'x|y<!--z-->w')
  # Each construct rendered once, correctly, in a single pass.
  [ "$out" = 'x&#124;y&lt;!--z--&gt;w' ]
}
