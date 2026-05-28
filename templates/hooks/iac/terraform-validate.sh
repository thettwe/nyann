#!/usr/bin/env bash
# terraform-validate — run `terraform validate` per detected module.
# Soft-skip when terraform isn't installed.
set -e
if ! command -v terraform >/dev/null 2>&1; then
  echo "[nyann iac] terraform CLI not installed — skipping validate"
  exit 0
fi
fail=0
# Iterate modules/* and environments/* (the conventional monorepo layouts).
for dir in modules/*/ environments/*/ stacks/*/; do
  [[ -d "$dir" ]] || continue
  # Only validate directories that contain at least one .tf file.
  if compgen -G "${dir}/*.tf" >/dev/null 2>&1; then
    ( cd "$dir" && terraform init -backend=false -input=false >/dev/null 2>&1 && terraform validate ) || {
      echo "[nyann iac] terraform validate FAILED in $dir"
      fail=1
    }
  fi
done
exit "$fail"
