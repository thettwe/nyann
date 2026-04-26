#!/usr/bin/env bats
# Enforces TECH §3.2 "SKILL body ≤ 500 lines" convention. Also sanity-checks
# that a deliberately-over-500-line fixture triggers the lint.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT="${REPO_ROOT}/tests/lint.sh"
}

@test "every SKILL.md is ≤ 500 lines" {
  while IFS= read -r -d '' skill; do
    lines=$(wc -l < "$skill" | tr -d ' ')
    [ "$lines" -le 500 ] || {
      echo "FAIL: $skill is $lines lines (> 500)"
      return 1
    }
  done < <(find "${REPO_ROOT}/skills" -name SKILL.md -print0)
}

@test "lint.sh rejects a >500-line SKILL.md fixture" {
  tmp_skills=$(mktemp -d)
  mkdir -p "$tmp_skills/giant"
  {
    for i in $(seq 1 600); do echo "line $i"; done
  } > "$tmp_skills/giant/SKILL.md"

  # Run lint.sh with SKILLS root patched via a throwaway repo layout.
  # Since lint.sh finds skills/ relative to its own parent, we build a
  # minimal repo-like dir and point it there.
  fakeroot=$(mktemp -d)
  mkdir "$fakeroot/bin" "$fakeroot/tests"
  cp "$LINT" "$fakeroot/tests/lint.sh"
  cp -r "$tmp_skills" "$fakeroot/skills"

  run bash "$fakeroot/tests/lint.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'lines (max 500)'
  rm -rf "$tmp_skills" "$fakeroot"
}
