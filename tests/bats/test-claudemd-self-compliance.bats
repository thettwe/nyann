#!/usr/bin/env bats
# This repo's own CLAUDE.md must satisfy nyann's router-mode invariant
# (≤ 3 KB soft cap). Guards against future regression — physician heal
# thyself per docs/principles/documentation.md property 2 (size-budgeted).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "CLAUDE.md exists at repo root" {
  [ -f "${REPO_ROOT}/CLAUDE.md" ]
}

@test "CLAUDE.md is under the 3 KB router-mode soft cap" {
  size=$(wc -c < "${REPO_ROOT}/CLAUDE.md" | tr -d ' ')
  [ "$size" -le 3072 ]
}

@test "CLAUDE.md is under the 8 KB hard cap" {
  size=$(wc -c < "${REPO_ROOT}/CLAUDE.md" | tr -d ' ')
  [ "$size" -le 8192 ]
}

@test "doctor flags CLAUDE.md status as ok (not warn or fail)" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not available"; fi
  status=$(bash "${REPO_ROOT}/bin/doctor.sh" --target "${REPO_ROOT}" --profile default --json 2>/dev/null \
    | jq -r '.documentation.claude_md.status // empty')
  [ "$status" = "ok" ]
}

@test "CLAUDE.md routes to extracted architecture and conventions docs" {
  grep -q "docs/architecture.md" "${REPO_ROOT}/CLAUDE.md"
  grep -q "docs/principles/conventions.md" "${REPO_ROOT}/CLAUDE.md"
}
