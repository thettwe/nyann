#!/usr/bin/env bash
# terraform-validate — run `terraform validate` per detected module.
# Soft-skip when terraform isn't installed.
#
# Critical: `terraform init` fetches provider plugins from the Terraform
# Registry, which makes a network call. Pre-commit hooks must not block
# on network availability. We therefore validate ONLY modules that have
# already been initialized (i.e. have a `.terraform/` directory). The
# first time a user touches a module they should run `terraform init`
# manually; subsequent commits get the validate check automatically.
set -e
if ! command -v terraform >/dev/null 2>&1; then
  echo "[nyann iac] terraform CLI not installed — skipping validate" >&2
  exit 0
fi
fail=0
skipped=0
for dir in modules/*/ environments/*/ stacks/*/; do
  [[ -d "$dir" ]] || continue
  if ! compgen -G "${dir}/*.tf" >/dev/null 2>&1; then
    continue
  fi
  if [[ ! -d "${dir}.terraform" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  ( cd "$dir" && terraform validate ) || {
    echo "[nyann iac] terraform validate FAILED in $dir" >&2
    fail=1
  }
done
if (( skipped > 0 && fail == 0 )); then
  echo "[nyann iac] terraform validate skipped $skipped module(s) without .terraform/ — run \`terraform init\` once per module to enable validation" >&2
fi
exit "$fail"
