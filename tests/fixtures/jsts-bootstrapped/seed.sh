#!/usr/bin/env bash
# Seeds git history for the jsts-bootstrapped fixture. Test callers run
# this against a temp copy before invoking learn-profile / doctor.

set -euo pipefail

target="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$target"

if [[ -d .git ]]; then
  rm -rf .git
fi

git init -q -b main
git -c user.email=fixture@nyann.local -c user.name=Fixture add \
  .gitignore .editorconfig CLAUDE.md commitlint.config.js package.json \
  tsconfig.json pnpm-lock.yaml hello.ts \
  .husky/pre-commit .husky/commit-msg \
  docs memory
git -c user.email=fixture@nyann.local -c user.name=Fixture commit -q \
  -m "feat: seed jsts-bootstrapped fixture"
