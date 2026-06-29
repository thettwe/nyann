#!/usr/bin/env bash
# kustomize-build-check — assert every Kustomize overlay still renders.
# Runs `kustomize build` against each overlays/*/ dir (and the repo root when it
# carries a kustomization file) and discards the output: we only care that the
# build succeeds. Soft-skips when `kustomize` is not installed.
#
# Pure local render — no cluster / network access — so it is pre-commit safe.
set -euo pipefail

if ! command -v kustomize >/dev/null 2>&1; then
  echo "[nyann iac] kustomize not installed — skipping (https://kustomize.io)"
  exit 0
fi

fail=0
checked=0

# _has_kustomization DIR — true when DIR contains a kustomization manifest.
_has_kustomization() {
  [[ -f "$1/kustomization.yaml" || -f "$1/kustomization.yml" || -f "$1/Kustomization" ]]
}

# Build each overlay (the deployable units), then the root if it is itself a
# kustomization target.
for dir in overlays/*/; do
  [[ -d "$dir" ]] || continue
  _has_kustomization "$dir" || continue
  checked=$((checked + 1))
  if ! kustomize build "$dir" >/dev/null; then
    echo "[nyann iac] kustomize build FAILED in $dir" >&2
    fail=1
  fi
done

if _has_kustomization .; then
  checked=$((checked + 1))
  if ! kustomize build . >/dev/null; then
    echo "[nyann iac] kustomize build FAILED at repo root" >&2
    fail=1
  fi
fi

if (( checked == 0 )); then
  echo "[nyann iac] no kustomization targets found — skipping"
  exit 0
fi

exit "$fail"
