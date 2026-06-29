#!/usr/bin/env bash
# ansible-lint — lint Ansible playbooks/roles for best-practice + correctness
# issues. Soft-skip when `ansible-lint` is not installed so a missing linter
# downgrades to a warning rather than blocking the commit (mirrors the
# terraform hook idiom).
set -euo pipefail
if ! command -v ansible-lint >/dev/null 2>&1; then
  echo "[nyann iac] ansible-lint not installed — skipping (https://ansible.readthedocs.io/projects/lint/)"
  exit 0
fi
# ansible-lint exits non-zero on findings; let that propagate to block the
# commit. No args → lint the whole repo using its own auto-detection.
ansible-lint
