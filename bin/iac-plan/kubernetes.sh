#!/usr/bin/env bash
# iac-plan/kubernetes.sh — ADVISORY raw-manifest plan adapter (text diff only).
#
# `kubectl diff` compares local manifests against the live cluster (unified
# diff text — no structured destroy count). Needs a reachable cluster + context;
# nyann never supplies kubeconfig/creds — kubectl uses the operator's ambient
# context. destructive_known FALSE (see _advisory.sh). Soft-skips when kubectl
# is absent or no cluster/manifest output is produced.
set -o errexit
set -o nounset
set -o pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_advisory.sh
source "${_script_dir}/_advisory.sh"

_adv_parse_args "$@"

# `kubectl diff -f <dir>` diffs every manifest in the unit dir against the
# cluster. Exit 1 means "there is a diff" (fine); >1 means error (soft-skip via
# empty-output check in _adv_run).
_adv_run kubectl kubectl-diff.txt "kubectl diff (advisory — text diff, no structured summary)" \
  -- kubectl diff -f .
