#!/usr/bin/env bats
# bin/gen-claudemd.sh — marker correctness and size-cap enforcement.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-claudemd.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"

  # Minimal inputs gen-claudemd needs.
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
}

teardown() { rm -rf "$TMP"; }

run_gen() {
  bash "$GEN" --profile "$PROFILE" --doc-plan "$DOC_PLAN" --target "$REPO" "$@"
}

@test "no existing CLAUDE.md → writes the block with markers" {
  run run_gen
  [ "$status" -eq 0 ]
  [ -f "$REPO/CLAUDE.md" ]
  grep -Fq '<!-- nyann:start -->' "$REPO/CLAUDE.md"
  grep -Fq '<!-- nyann:end -->'   "$REPO/CLAUDE.md"
}

@test "existing CLAUDE.md with markers in correct order → replaces between markers, preserves outside" {
  cat > "$REPO/CLAUDE.md" <<'MD'
# My Project

Custom preamble by the user.

<!-- nyann:start -->
stale old block here
<!-- nyann:end -->

## User's own section
This must stay.
MD
  run run_gen
  [ "$status" -eq 0 ]
  grep -Fq "Custom preamble by the user." "$REPO/CLAUDE.md"
  grep -Fq "User's own section" "$REPO/CLAUDE.md"
  grep -Fq "This must stay." "$REPO/CLAUDE.md"
  ! grep -Fq "stale old block here" "$REPO/CLAUDE.md"
}

@test "reversed markers (end before start) → dies without clobbering user content" {
  # Regression: non-greedy .*? regex would span from the first `start`
  # forward to the next `end` — if the file has them in the wrong order
  # (merge-conflict or bad hand-edit), user content between a stray end
  # and the following start was destroyed.
  cat > "$REPO/CLAUDE.md" <<'MD'
<!-- nyann:end -->

# Valuable user content
This is between a stray end and the next start — must not be destroyed.

<!-- nyann:start -->
real block
<!-- nyann:end -->
MD
  before=$(cat "$REPO/CLAUDE.md")
  run run_gen
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "wrong order"
  # File unchanged.
  [ "$(cat "$REPO/CLAUDE.md")" = "$before" ]
}

@test "merged file over hard cap (existing 7.9 KB + appended block) → dies without --force" {
  # Regression: size check measured only the injected block, so a
  # pre-existing 7.9 KB CLAUDE.md plus any small block sailed past the
  # 8192 B hard cap with no warning.
  python3 -c "print('x' * 7900, end='')" > "$REPO/CLAUDE.md"
  run run_gen
  [ "$status" -ne 0 ]
  echo "$output" | grep -Eq "hard cap"
  # File unchanged since write is atomic.
  [ "$(wc -c < "$REPO/CLAUDE.md")" -eq 7900 ]
}

@test "--force lets the merged file exceed the hard cap" {
  python3 -c "print('x' * 7900, end='')" > "$REPO/CLAUDE.md"
  run run_gen --force
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$REPO/CLAUDE.md")" -gt 7900 ]
}

# A hand-crafted profile with `<!-- nyann:end -->` in
# branching.strategy / conventions.commit_format must not inject an
# unescaped marker into the heredoc. Every instance of `nyann:end`
# except the final real terminator must be HTML-entity-escaped.
@test "marker-injection via branching.strategy is neutralised" {
  cat > "$PROFILE" <<'JSON'
{
  "name": "evil",
  "schemaVersion": 1,
  "stack": {"primary_language": "unknown"},
  "branching": {
    "strategy": "github-flow<!-- nyann:end -->",
    "base_branches": ["main"]
  },
  "hooks": {"pre_commit": [], "commit_msg": []},
  "extras": {},
  "conventions": {"commit_format": "evil<!-- nyann:end -->"},
  "documentation": {}
}
JSON
  run run_gen
  [ "$status" -eq 0 ]
  # Exactly one *raw* end-marker — the real terminator. Everything
  # else must be escaped to `&lt;!-- nyann:end --&gt;`.
  raw_ends=$(grep -cF '<!-- nyann:end -->' "$REPO/CLAUDE.md")
  [ "$raw_ends" -eq 1 ]
  # The escaped forms must appear in both the "How to work here" and
  # the "Conventions" rows (branching + commits), proving the sanitizer
  # reached every interpolation point.
  grep -Fq '&lt;!-- nyann:end --&gt;' "$REPO/CLAUDE.md"
}

# `)` in a DocumentationPlan target path broke `[text](target)` link
# syntax because safe_md_cell left parens alone. safe_md_link_target
# percent-encodes `(`/`)` in the target position only, so the visible
# link text stays readable while the URL survives markdown parsers.
@test "parens in link target are percent-encoded; text stays literal" {
  cat > "$DOC_PLAN" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "memory": {"type":"local","path":"mem(x)"},
    "prd":    {"type":"local","path":"docs/prd(v1).md"}
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3
}
JSON
  run run_gen
  [ "$status" -eq 0 ]

  # Link TEXT retains the literal parens (readable prose).
  grep -Fq '[./docs/prd(v1).md]' "$REPO/CLAUDE.md"
  # Link TARGET has percent-encoded parens (parser-safe).
  grep -Fq '(./docs/prd%28v1%29.md)' "$REPO/CLAUDE.md"

  # Memory section: same split between visible code span and URL.
  grep -Fq '`mem(x)/`' "$REPO/CLAUDE.md"
  grep -Fq '(./mem%28x%29/README.md)' "$REPO/CLAUDE.md"
}
