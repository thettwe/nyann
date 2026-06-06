#!/usr/bin/env bats
# bin/install-hooks.sh --iac --iac-tool <tool> — per-tool dispatch tests.
#
# Covers the IaC dispatcher added for v1.13.0 (install_iac_phase +
# _iac_hook_spec): each tool must materialize the CORRECT wrapper scripts
# into .nyann/hooks/iac/ (terraform → flat terraform-*.sh; every other tool
# → <subdir>/<scripts>.sh) AND select the matching per-tool pre-commit config.
#
# We never run `pre-commit install` (network-heavy), so every invocation
# passes --no-install-hook. Assertions check materialized files + the
# distinguishing first IaC hook id in the written .pre-commit-config.yaml
# (each config carries a unique tool hook: terraform-fmt / cdk-synth-check /
# pulumi-preview-check / kubeconform / helm-lint / ansible-lint).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL="${REPO_ROOT}/bin/install-hooks.sh"
}

seed_repo() {
  # Bare git repo in a fresh tmpdir — IaC phase only needs .git to exist.
  local tmp
  tmp=$(mktemp -d)
  ( cd "$tmp" && git init -q -b main )
  printf '%s' "$tmp"
}

# ---- per-tool dispatch ----------------------------------------------------
# Each test asserts: (a) exit 0, (b) the .nyann/hooks/iac/ layout matches the
# dispatch table in _iac_hook_spec, (c) the selected pre-commit config is the
# tool's own (via its unique hook id), and (d) the WRONG tool's scripts/config
# did not leak in.

@test "--iac --iac-tool terraform → flat terraform-*.sh + iac.yaml" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool terraform --no-install-hook
  [ "$status" -eq 0 ]
  # Flat layout (no subdir) — historical terraform behaviour.
  [ -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/terraform-validate.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/tflint.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/tfsec.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/terraform-docs.sh" ]
  # No subdir should be created for the flat layout.
  [ ! -d "$tmp/.nyann/hooks/iac/cdk" ]
  # iac.yaml selected (its distinguishing hook is terraform-fmt).
  grep -Fq 'id: terraform-fmt' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool opentofu → same flat terraform set (alias)" {
  # opentofu shares terraform's flat hook set + iac.yaml per _iac_hook_spec.
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool opentofu --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/terraform-validate.sh" ]
  [ ! -d "$tmp/.nyann/hooks/iac/cdk" ]
  grep -Fq 'id: terraform-fmt' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool aws-cdk → cdk/ subdir scripts + iac-cdk.yaml" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool aws-cdk --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/cdk/cdk-synth-check.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/cdk/cdk-diff.sh" ]
  # Terraform's flat scripts must NOT be installed for cdk.
  [ ! -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  # iac-cdk.yaml selected (distinguishing hook: cdk-synth-check).
  grep -Fq 'id: cdk-synth-check' "$tmp/.pre-commit-config.yaml"
  ! grep -Fq 'id: terraform-fmt' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool cdk (short tag) → cdk/ subdir scripts + iac-cdk.yaml" {
  # detect-iac.sh emits the short `cdk` framework tag; the dispatcher
  # normalizes it to the same hook set as aws-cdk.
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool cdk --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/cdk/cdk-synth-check.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/cdk/cdk-diff.sh" ]
  grep -Fq 'id: cdk-synth-check' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool pulumi → pulumi/ subdir script + iac-pulumi.yaml" {
  # NOTE: iac-pulumi.yaml is added by a sibling fix; this asserts pulumi
  # selects it (not the iac.yaml fallback).
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool pulumi --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/pulumi/pulumi-preview-check.sh" ]
  [ ! -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  # iac-pulumi.yaml selected (distinguishing hook: pulumi-preview-check).
  grep -Fq 'id: pulumi-preview-check' "$tmp/.pre-commit-config.yaml"
  ! grep -Fq 'id: terraform-fmt' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool kubernetes → k8s/ subdir scripts + iac-k8s.yaml" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool kubernetes --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/k8s/kubeconform.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/k8s/kube-linter.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/k8s/kustomize-build-check.sh" ]
  [ ! -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  grep -Fq 'id: kubeconform' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool kustomize → same k8s/ set (alias) + iac-k8s.yaml" {
  # kustomize shares kubernetes' hook set + iac-k8s.yaml per _iac_hook_spec.
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool kustomize --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/k8s/kubeconform.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/k8s/kustomize-build-check.sh" ]
  grep -Fq 'id: kubeconform' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool helm → helm/ subdir scripts + iac-helm.yaml" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool helm --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/helm/helm-lint.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/helm/helm-template-check.sh" ]
  [ ! -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  grep -Fq 'id: helm-lint' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--iac --iac-tool ansible → ansible/ subdir scripts + iac-ansible.yaml" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool ansible --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/ansible/ansible-lint.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/ansible/yamllint.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/ansible/ansible-syntax-check.sh" ]
  [ ! -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  grep -Fq 'id: ansible-lint' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

# ---- back-compat ----------------------------------------------------------

@test "--iac with NO --iac-tool defaults to the terraform set (back-compat)" {
  # A bare `--iac` (the historical invocation) must behave exactly as
  # `--iac --iac-tool terraform`: flat terraform-*.sh + iac.yaml.
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.nyann/hooks/iac/terraform-fmt.sh" ]
  [ -f "$tmp/.nyann/hooks/iac/tflint.sh" ]
  [ ! -d "$tmp/.nyann/hooks/iac/cdk" ]
  grep -Fq 'id: terraform-fmt' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

# ---- unknown tool soft-skip ----------------------------------------------

@test "--iac --iac-tool <unknown> soft-skips (exit 0, no scripts, no config)" {
  # An unrecognised tool must NOT install a wrong set — it soft-skips with
  # a structured skip record and a clean exit, leaving the repo untouched.
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --iac --iac-tool not-a-real-tool --no-install-hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"skipped":"iac-hooks"'
  echo "$output" | grep -Fq 'unknown iac tool: not-a-real-tool'
  # Nothing materialized — neither the .nyann tree nor a pre-commit config.
  [ ! -d "$tmp/.nyann/hooks/iac" ]
  [ ! -f "$tmp/.pre-commit-config.yaml" ]
  rm -rf "$tmp"
}
