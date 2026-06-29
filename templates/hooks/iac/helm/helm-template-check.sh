#!/usr/bin/env bash
# helm-template-check — render the chart with `helm template` and fail when
# templating errors out (bad Go-template syntax, missing required values, etc.).
# Rendering catches breakage that `helm lint` alone misses, before it reaches a
# cluster. Output is discarded — we only care about the exit status here.
# Soft-skip when the `helm` CLI is absent, same idiom as the other IaC hooks.
set -euo pipefail
if ! command -v helm >/dev/null 2>&1; then
  echo "[nyann iac] helm not installed — skipping helm template check (https://helm.sh/docs/intro/install/)"
  exit 0
fi
# `helm template .` renders all manifests to stdout; a templating failure exits
# non-zero. Discard the rendered YAML — we validate, we don't apply.
helm template . >/dev/null
