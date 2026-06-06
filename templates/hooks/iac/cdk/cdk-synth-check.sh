#!/usr/bin/env bash
# cdk-synth-check — fail when the CDK app does not synthesize cleanly.
#
# Runs `cdk synth --quiet`, which renders the CloudFormation template without
# writing it to stdout. This catches construct-time errors (bad props, broken
# imports, invalid stack wiring) at commit time, before they reach a `cdk
# deploy`. Pure synth: it builds the template from local code and NEVER calls
# AWS or requires bootstrapped credentials, so it is safe in a pre-commit hook.
#
# Soft-skip when the `cdk` CLI is not installed (mirrors the terraform hooks):
# a missing CLI downgrades to a warning rather than blocking the commit, so a
# contributor without the AWS CDK toolkit can still commit.
set -euo pipefail

if ! command -v cdk >/dev/null 2>&1; then
  echo "[nyann iac] cdk CLI not installed — skipping synth check (https://docs.aws.amazon.com/cdk/v2/guide/cli.html)"
  exit 0
fi

# `--quiet` suppresses the template dump but still exits non-zero on any synth
# error. We capture output so a failure prints actionable context.
if ! out=$(cdk synth --quiet 2>&1); then
  echo "[nyann iac] cdk synth failed:" >&2
  echo "$out" >&2
  echo "Run \`cdk synth\` locally to reproduce." >&2
  exit 1
fi
exit 0
