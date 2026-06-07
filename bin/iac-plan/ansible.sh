#!/usr/bin/env bash
# iac-plan/ansible.sh — ADVISORY Ansible plan adapter (check-mode diff only).
#
# `ansible-playbook --check --diff` does a dry run with a textual diff of file/
# template changes. There is no machine-readable resource-action summary and no
# meaningful "destroy" concept, so destructive_known is FALSE (see _advisory.sh)
# — the spec marks Ansible plan as advisory ("n/a" destroy detection). Needs an
# inventory + connectivity; nyann supplies no credentials. Soft-skips when
# ansible-playbook is absent or check-mode produces no output.
set -o errexit
set -o nounset
set -o pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_advisory.sh
source "${_script_dir}/_advisory.sh"

_adv_parse_args "$@"

# Pick a playbook to check: prefer site.yml / playbook.yml at the unit root.
# unit_dir / raw_dir are set by _adv_parse_args in the sourced _advisory.sh
# (the linter can't follow the source, so SC2154 is silenced below).
playbook=""
# shellcheck disable=SC2154
for cand in site.yml site.yaml playbook.yml playbook.yaml main.yml main.yaml; do
  if [[ -f "$unit_dir/$cand" ]]; then playbook="$cand"; break; fi
done
if [[ -z "$playbook" ]]; then
  printf 'no playbook (site.yml/playbook.yml) at unit root — skipping ansible check\n' >&2
  exit 3
fi

_adv_run ansible-playbook ansible-check.txt "ansible-playbook --check --diff (advisory — dry run, no structured summary)" \
  -- ansible-playbook --check --diff "$playbook"
