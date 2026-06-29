#!/usr/bin/env bash
# kube-linter — security / best-practice lint for Kubernetes manifests.
# Soft-skips when `kube-linter` is not installed so a missing binary downgrades
# to a warning rather than blocking the commit.
#
# kube-linter reads manifests off disk only — no cluster / network access — so
# it is safe to run from a pre-commit hook.
set -euo pipefail

if ! command -v kube-linter >/dev/null 2>&1; then
  echo "[nyann iac] kube-linter not installed — skipping (https://github.com/stackrox/kube-linter)"
  exit 0
fi

# `lint .` recurses the working tree; a non-zero exit means a check failed.
kube-linter lint .
