#!/usr/bin/env bash
# tfsec — security scan. Soft-skip when not installed.
set -e
if ! command -v tfsec >/dev/null 2>&1; then
  echo "[nyann iac] tfsec not installed — skipping (https://github.com/aquasecurity/tfsec)"
  exit 0
fi
tfsec .
