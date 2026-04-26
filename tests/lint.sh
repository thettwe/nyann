#!/usr/bin/env bash
# tests/lint.sh — shellcheck + SKILL-length enforcement.
#
# Runs shellcheck over every bin/*.sh and template hook that's actually a
# shell script. Also asserts every skills/<skill>/SKILL.md body ≤ 500 lines.
# Exits non-zero on any finding.

set -o errexit
set -o nounset
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

errors=0

# --- shellcheck -------------------------------------------------------------

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "lint: shellcheck not installed; install via 'brew install shellcheck' to run this step" >&2
  errors=$((errors + 1))
else
  shell_files=(
    bin/*.sh
    templates/hooks/pre-commit
    templates/hooks/commit-msg
    templates/husky/pre-commit
    templates/husky/commit-msg
  )
  # --severity=info catches SC2295 (unquoted expansion in ${..}),
  # SC2329 (declared-but-unused functions), and SC2016 (single-quoted
  # text containing backticks/dollar-signs). Each one is either a real
  # bug or wants an explicit `# shellcheck disable=...` comment with
  # rationale; tightening the gate forces that discipline.
  echo "lint: shellcheck over ${#shell_files[@]} file(s)"
  if ! shellcheck --shell=bash --exclude=SC1091 --severity=info "${shell_files[@]}"; then
    errors=$((errors + 1))
  fi
fi

# --- SKILL.md length ≤ 500 -------------------------------------------------

max_skill_lines=500

while IFS= read -r -d '' skill; do
  lines=$(wc -l < "$skill" | tr -d ' ')
  if (( lines > max_skill_lines )); then
    echo "lint: $skill has $lines lines (max $max_skill_lines)" >&2
    errors=$((errors + 1))
  else
    echo "lint: $skill — $lines lines (OK)"
  fi
done < <(find skills -name SKILL.md -print0)

# --- summary ---------------------------------------------------------------

if (( errors > 0 )); then
  echo "lint: FAILED with $errors issue(s)" >&2
  exit 1
fi
echo "lint: OK"
