#!/usr/bin/env bash
# iac-plan/kustomize.sh — ADVISORY Kustomize plan adapter (text diff only).
#
# `kubectl diff -k <overlay>` builds the overlay and diffs against the cluster.
# Unified-diff text, no structured destroy count → destructive_known FALSE
# (see _advisory.sh). Needs a reachable cluster + context (operator's ambient
# kubeconfig; nyann supplies none). Soft-skips when kubectl is absent or the
# build/diff produces no output.
set -o errexit
set -o nounset
set -o pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_advisory.sh
source "${_script_dir}/_advisory.sh"

_adv_parse_args "$@"

_adv_run kubectl kustomize-diff.txt "kubectl diff -k (advisory — text diff, no structured summary)" \
  -- kubectl diff -k .
