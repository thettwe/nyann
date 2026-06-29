#!/usr/bin/env bash
# yamllint — lint YAML syntax/style across the repo (playbooks, vars,
# inventory). Soft-skip when `yamllint` is not installed so the absence of the
# linter warns rather than blocks (mirrors the terraform hook idiom).
set -euo pipefail
if ! command -v yamllint >/dev/null 2>&1; then
  echo "[nyann iac] yamllint not installed — skipping (https://yamllint.readthedocs.io/)"
  exit 0
fi
# yamllint exits non-zero on errors; let that propagate. '.' lints the tree
# honoring any .yamllint config the repo ships.
yamllint .
