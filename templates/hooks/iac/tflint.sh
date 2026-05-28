#!/usr/bin/env bash
# tflint — run TFLint at the repo root. Soft-skip when not installed.
set -e
if ! command -v tflint >/dev/null 2>&1; then
  echo "[nyann iac] tflint not installed — skipping (https://github.com/terraform-linters/tflint)"
  exit 0
fi
tflint --recursive
