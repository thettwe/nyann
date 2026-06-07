#!/usr/bin/env bash
# iac-plan/helm.sh — ADVISORY Helm plan adapter (text diff only in v1.13.0).
#
# Prefers `helm diff upgrade` (helm-diff plugin) which shows the resource delta
# against the release; falls back to `helm template` (render-only, no cluster).
# Either way the output is a human diff with no structured destroy count, so
# destructive_known is FALSE (see _advisory.sh). Soft-skips when helm is absent.
set -o errexit
set -o nounset
set -o pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_advisory.sh
source "${_script_dir}/_advisory.sh"

_adv_parse_args "$@"

# unit_dir / raw_dir are set by _adv_parse_args in the sourced _advisory.sh
# (the linter can't follow the source, so SC2154 is silenced below).
# shellcheck disable=SC2154
# Prefer the helm-diff plugin (shows release delta); else template-render.
if command -v helm >/dev/null 2>&1 && helm plugin list 2>/dev/null | grep -qiw diff; then
  _adv_run helm helm-diff.txt "helm diff (advisory — text diff, no structured summary)" \
    -- helm diff upgrade --allow-unreleased "$(basename "$unit_dir")" .
else
  _adv_run helm helm-template.txt "helm template (advisory — render only, no release delta)" \
    -- helm template .
fi
