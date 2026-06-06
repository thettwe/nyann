#!/usr/bin/env bash
# kubeconform — schema-validate Kubernetes manifests against the upstream
# OpenAPI schemas. Soft-skips when `kubeconform` is not installed so a missing
# binary downgrades to a warning rather than blocking the commit.
#
# We never reach out to a cluster: kubeconform validates against bundled /
# cached JSON schemas. `-ignore-missing-schemas` keeps CRDs from failing the
# run (kube-linter / kustomize-build-check cover those paths instead).
set -euo pipefail

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "[nyann iac] kubeconform not installed — skipping (https://github.com/yannh/kubeconform)"
  exit 0
fi

# Validate the whole tree. `-summary` prints a one-line tally; a non-zero exit
# means at least one manifest failed schema validation.
kubeconform -summary -ignore-missing-schemas -strict .
