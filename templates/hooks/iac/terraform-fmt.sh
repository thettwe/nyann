#!/usr/bin/env bash
# terraform-fmt — fail when any *.tf file isn't terraform-formatted.
# Soft-skip when `terraform` is not installed.
set -e
if ! command -v terraform >/dev/null 2>&1; then
  echo "[nyann iac] terraform CLI not installed — skipping fmt check"
  exit 0
fi
# `terraform fmt -check -recursive` exits non-zero if any file needs formatting.
out=$(terraform fmt -check -recursive 2>&1) || {
  echo "[nyann iac] terraform fmt found unformatted files:"
  echo "$out"
  echo "Run: terraform fmt -recursive"
  exit 1
}
exit 0
