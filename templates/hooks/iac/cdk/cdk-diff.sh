#!/usr/bin/env bash
# cdk-diff — advisory `cdk diff` that surfaces the resource delta of the
# pending change. Intended for PR-time / pre-push use, not as a blocking gate.
#
# `cdk diff` compares the synthesized template against the DEPLOYED stack, so
# it reaches AWS and needs bootstrapped credentials. This script therefore:
#   - soft-skips when the `cdk` CLI is absent (like every nyann IaC hook), and
#   - is ADVISORY: it prints the diff for the author's awareness but ALWAYS
#     exits 0 (even when diff reports drift or hits a credentials error), so a
#     missing/locked AWS context never blocks the commit or push.
#
# This keeps the destructive-change conversation in front of the human without
# coupling the hook to live cloud access.
set -euo pipefail

if ! command -v cdk >/dev/null 2>&1; then
  echo "[nyann iac] cdk CLI not installed — skipping diff advisory (https://docs.aws.amazon.com/cdk/v2/guide/cli.html)"
  exit 0
fi

echo "[nyann iac] cdk diff (advisory — does not block):"
# `cdk diff` exits 1 when there is a diff and >1 on error; both are fine here.
# We never propagate that status, because this hook only informs.
if ! cdk diff 2>&1; then
  echo "[nyann iac] cdk diff could not complete (likely missing AWS credentials or bootstrap) — advisory only, not blocking."
fi
exit 0
