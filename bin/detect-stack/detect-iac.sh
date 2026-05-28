#!/usr/bin/env bash
# detect-stack/detect-iac.sh — IaC detection module sourced by detect-stack.sh
# (v1.12.0 / I1, minimal). Sets the following globals on hit:
#   IS_INFRA=1
#   IAC_FRAMEWORK=<terraform|cdk|pulumi|helm|kustomize>
#
# Heuristics:
#   *.tf in root or modules/ → terraform
#   cdk.json + lib/*.{ts,py} → cdk
#   Pulumi.yaml              → pulumi
#   Chart.yaml               → helm
#   kustomization.yaml       → kustomize
#
# Pure detection — never writes to disk.

nyann::detect_iac() {
  local target="${1-.}"
  IS_INFRA=0
  IAC_FRAMEWORK=""

  # Terraform: *.tf at root or under modules/, stacks/, environments/.
  if find "$target" -maxdepth 1 -name '*.tf' 2>/dev/null | head -1 | grep -q .; then
    IS_INFRA=1
    IAC_FRAMEWORK="terraform"
    return 0
  fi
  for d in modules stacks environments envs; do
    if [[ -d "$target/$d" ]] && find "$target/$d" -maxdepth 3 -name '*.tf' 2>/dev/null | head -1 | grep -q .; then
      IS_INFRA=1
      IAC_FRAMEWORK="terraform"
      return 0
    fi
  done

  # AWS CDK.
  if [[ -f "$target/cdk.json" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="cdk"
    return 0
  fi

  # Pulumi.
  if [[ -f "$target/Pulumi.yaml" || -f "$target/Pulumi.yml" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="pulumi"
    return 0
  fi

  # Helm chart.
  if [[ -f "$target/Chart.yaml" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="helm"
    return 0
  fi

  # Kustomize.
  if [[ -f "$target/kustomization.yaml" || -f "$target/kustomization.yml" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="kustomize"
    return 0
  fi

  return 1
}
