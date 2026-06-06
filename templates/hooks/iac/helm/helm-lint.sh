#!/usr/bin/env bash
# helm-lint — run `helm lint` over the chart at the repo root.
# Soft-skip when the `helm` CLI is not installed (mirrors terraform-fmt.sh):
# a missing tool downgrades the check to a no-op rather than blocking the
# commit, because nyann never hard-requires a tool the operator hasn't chosen.
set -euo pipefail
if ! command -v helm >/dev/null 2>&1; then
  echo "[nyann iac] helm not installed — skipping helm lint (https://helm.sh/docs/intro/install/)"
  exit 0
fi
# `helm lint .` exits non-zero on errors so the failure propagates to the hook;
# we run against the chart dir (repo root) so umbrella + single charts both work.
helm lint .
