#!/usr/bin/env bash
# detect-stack/detect-iac.sh — IaC detection module sourced by detect-stack.sh.
# Sets the following globals on hit:
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

  # Terraform: *.tf at root or under conventional IaC directories. We
  # check both immediate-children layouts (`modules/<name>/main.tf`) and
  # the common nested-under-a-top-level-dir layout
  # (`infrastructure/modules/<name>/main.tf`,
  # `terraform/environments/<env>/main.tf`).
  if find "$target" -maxdepth 1 -name '*.tf' 2>/dev/null | head -1 | grep -q .; then
    IS_INFRA=1
    IAC_FRAMEWORK="terraform"
    return 0
  fi
  for d in modules stacks environments envs infrastructure terraform iac infra deploy; do
    [[ -d "$target/$d" ]] || continue
    # -maxdepth 5 catches both `infrastructure/main.tf` and
    # `infrastructure/modules/aws/networking/main.tf`. Going deeper costs
    # little because the directory list is short and find prunes hidden
    # dirs we don't care about (.git etc.) once they're skipped.
    if find "$target/$d" -maxdepth 5 -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | head -1 | grep -q .; then
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

  # Helm chart. Require corroboration (values.yaml or templates/) — a bare
  # Chart.yaml at the root is ambiguous (CD tools and packaging metadata also
  # use that name) and would misclassify an app repo as infra.
  if [[ -f "$target/Chart.yaml" ]] \
     && { [[ -f "$target/values.yaml" ]] || [[ -f "$target/values.yml" ]] || [[ -d "$target/templates" ]]; }; then
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
