#!/usr/bin/env bash
# pulumi-preview-check — advisory `pulumi preview --diff` for the current stack.
#
# Soft-skip when the `pulumi` CLI is not installed: detection and commits must
# never block on a tool the developer hasn't provisioned (mirrors the terraform
# hook idiom). This hook is ADVISORY — `pulumi preview` needs a configured
# backend + cloud credentials, which a pre-commit run may not have, so a failed
# or unauthenticated preview must not break the commit. We surface the diff for
# awareness and always exit 0.
set -euo pipefail

if ! command -v pulumi >/dev/null 2>&1; then
  echo "[nyann iac] pulumi not installed — skipping (https://www.pulumi.com/docs/install/)"
  exit 0
fi

# A Pulumi project is required for `preview` to mean anything. Without one,
# there is nothing to diff — skip rather than error.
if [[ ! -f Pulumi.yaml && ! -f Pulumi.yml ]]; then
  echo "[nyann iac] no Pulumi.yaml at repo root — skipping pulumi preview"
  exit 0
fi

# Advisory preview: `--diff` shows resource-level changes, `--non-interactive`
# prevents any prompt from hanging a hook. A non-zero exit (e.g. no backend /
# no creds / not logged in) is reported but never fails the commit.
echo "[nyann iac] pulumi preview (advisory — informational only):"
if ! pulumi preview --diff --non-interactive 2>&1; then
  echo "[nyann iac] pulumi preview could not run (no backend/credentials?) — advisory only, not blocking"
fi
exit 0
