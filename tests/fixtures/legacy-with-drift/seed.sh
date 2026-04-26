#!/usr/bin/env bash
# Seeds a fresh .git directory under this fixture with deliberately
# non-Conventional commit messages + one compliant commit, so retrofit /
# doctor can demonstrate NON-COMPLIANT HISTORY detection.
#
# Usage: ./seed.sh [<target-dir>]
# When called without args, seeds this fixture in-place.
# Callers running against a temp copy should pass the copy's path.

set -euo pipefail

target="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "$target"

if [[ -d .git ]]; then
  rm -rf .git
fi

git init -q -b main
git -c user.email=fixture@nyann.local -c user.name=Fixture add .gitignore package.json tsconfig.json pnpm-lock.yaml
git -c user.email=fixture@nyann.local -c user.name=Fixture commit -q -m "initial"
echo "# README" > README.md
git -c user.email=fixture@nyann.local -c user.name=Fixture add README.md
git -c user.email=fixture@nyann.local -c user.name=Fixture commit -q -m "added readme"
echo "console.log('hi')" > app.js
git -c user.email=fixture@nyann.local -c user.name=Fixture add app.js
git -c user.email=fixture@nyann.local -c user.name=Fixture commit -q -m "random stuff"
echo "// change" >> app.js
git -c user.email=fixture@nyann.local -c user.name=Fixture add app.js
git -c user.email=fixture@nyann.local -c user.name=Fixture commit -q -m "fix: proper CC message"
echo "// more" >> app.js
git -c user.email=fixture@nyann.local -c user.name=Fixture add app.js
git -c user.email=fixture@nyann.local -c user.name=Fixture commit -q -m "WIP"
