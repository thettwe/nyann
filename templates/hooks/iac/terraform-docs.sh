#!/usr/bin/env bash
# terraform-docs — regenerate module README.md files.
# Soft-skip when not installed.
set -e
if ! command -v terraform-docs >/dev/null 2>&1; then
  echo "[nyann iac] terraform-docs not installed — skipping (https://terraform-docs.io)"
  exit 0
fi
for dir in modules/*/; do
  [[ -d "$dir" ]] || continue
  if compgen -G "${dir}/*.tf" >/dev/null 2>&1; then
    terraform-docs markdown table --output-file README.md --output-mode inject "$dir" >/dev/null
  fi
done
# If any README was modified, stage it so the commit is up to date.
git add -- modules/*/README.md 2>/dev/null || true
exit 0
