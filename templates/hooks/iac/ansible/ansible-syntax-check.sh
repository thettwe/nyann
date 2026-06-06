#!/usr/bin/env bash
# ansible-syntax-check — parse-only validation of playbooks via
# `ansible-playbook --syntax-check`. Catches malformed YAML / unknown
# directives without contacting any host (no SSH, no inventory connection).
# Soft-skip when `ansible-playbook` is not installed (mirrors the terraform
# hook idiom).
set -euo pipefail
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "[nyann iac] ansible-playbook not installed — skipping syntax-check (https://docs.ansible.com/)"
  exit 0
fi

# Collect top-level playbooks: *.yml/*.yaml at the repo root that declare a
# play (hosts: + tasks:/roles:). Same heuristic detect-iac.sh uses, so the
# hook checks exactly what nyann classified as playbooks. Nothing to check is
# a clean pass, not a failure.
shopt -s nullglob
status=0
checked=0
for pb in ./*.yml ./*.yaml; do
  [[ -f "$pb" ]] || continue
  if grep -Eq '^[[:space:]]*-?[[:space:]]*hosts:' "$pb" 2>/dev/null \
     && grep -Eq '^[[:space:]]*(tasks|roles):' "$pb" 2>/dev/null; then
    checked=$((checked + 1))
    if ! ansible-playbook --syntax-check "$pb"; then
      status=1
    fi
  fi
done

if [[ "$checked" -eq 0 ]]; then
  echo "[nyann iac] ansible-syntax-check: no top-level playbooks found — nothing to check"
fi
exit "$status"
