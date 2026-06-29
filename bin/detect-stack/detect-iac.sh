#!/usr/bin/env bash
# detect-stack/detect-iac.sh — IaC detection module sourced by detect-stack.sh.
#
# Sets the following globals on a hit (all are reset on every call so a
# no-match leaves no stale state behind):
#   IS_INFRA=1
#   IAC_FRAMEWORK=<terraform|cdk|pulumi|helm|kubernetes|ansible>
#                  ^ the SHORT producer tag written into the descriptor's
#                    `framework` enum, used for profile matching. Two tools
#                    intentionally map to a different tag than their iac.tool:
#                    aws-cdk → cdk, and kustomize → kubernetes (the
#                    kubernetes-app profile covers both manifest + kustomize
#                    layouts). The precise tool is preserved in IAC_TOOL.
#   IAC_TOOL=<terraform|aws-cdk|pulumi|helm|kustomize|kubernetes|ansible>
#                  ^ the `iac.tool` enum value (long form, schema-aligned).
#   IAC_LANGUAGE=<hcl|typescript|python|go|csharp|yaml>   (may be empty)
#   IAC_UNITS_JSON=<jq array of {kind,path,name,version}>  (default [])
#   IAC_LOCKFILES_JSON=<jq array of strings>               (default [])
#   IAC_VAR_FILES_JSON=<jq array of strings>               (default [])
#
# PRECEDENCE (critical — first match wins via `return 0`):
#
#   1. Chart.yaml (+ corroboration)        → helm
#   2. kustomization.yaml                  → kustomize
#   3. *.tf (root or conventional dirs)    → terraform
#   4. cdk.json                            → aws-cdk
#   5. Pulumi.yaml / Pulumi.yml            → pulumi
#   6. ansible.cfg / roles/*/tasks/main.yml / top-level playbook → ansible
#   7. bare K8s manifests (apiVersion:+kind:, no kustomization, no CI yaml) → kubernetes
#
# This ordering is deliberate and unambiguous:
#   - A Helm chart dir whose templates/ contains k8s-looking manifests
#     classifies as HELM (step 1), never kubernetes (step 7), because
#     Chart.yaml is checked first and short-circuits.
#   - An Ansible playbook .yml (hosts: + tasks:/roles:) classifies as
#     ANSIBLE (step 6), never kubernetes (step 7): bare-k8s is LAST and
#     requires apiVersion:+kind:, which a playbook never has.
#   - kustomize beats bare-k8s for the same reason (step 2 before step 7).
#   - A repo with BOTH cdk.json and a stray *.tf classifies as terraform
#     (step 3 before step 4): the .tf is treated as the deployable IaC and
#     CDK as tooling around it. Rare; flip the order only if a real case
#     argues otherwise. Detection is repo-ROOT only for non-terraform tools
#     (deep monorepo subdir discovery is deferred to v1.13.0 I7).
#
# Pure detection — never writes to disk. NEVER shells out to cdk / pulumi /
# kubectl / helm / ansible CLIs during detection (those need creds / network).
# Language + version reads use jq (JSON) and a python3+PyYAML-gated path with
# a grep fallback (YAML), so detection still works on minimal Unix hosts.

# _iac_yaml_key TARGET FILE KEY — echo the scalar value of a top-level YAML
# key (best-effort, shallow). Tries python3+PyYAML when available, falls back
# to a guarded grep so a host without PyYAML still gets shallow keys. Echoes
# nothing when the key is absent or unreadable. Never a hard dependency.
_iac_yaml_key() {
  local file="$1" key="$2" val=""
  [[ -f "$file" ]] || return 0
  if nyann::has_python_yaml; then
    val=$(python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        data = yaml.safe_load(fh) or {}
    v = data.get(sys.argv[2], "") if isinstance(data, dict) else ""
    print("" if v is None else str(v))
except Exception:
    print("")
PY
)
  fi
  if [[ -z "$val" ]]; then
    # grep fallback: top-level `key: value` (tolerates leading space).
    val=$(grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -1 \
      | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//")
  fi
  printf '%s' "$val"
}

# Unit objects ({kind,path,name,version[,depends_on]}) are now built by the
# deep discovery module (detect-stack/discover-iac-units.sh, sourced below via
# nyann::discover_iac_units) rather than appended inline here — that module owns
# the fuller unit set + the depends_on graph. detect-iac.sh keeps only the
# coarse tool classification plus the lockfile/var_file scans discovery does not
# produce.

# _iac_str_append JSON_VAR VALUE — append a string to the named jq-array var.
_iac_str_append() {
  local _var="$1" _val="$2"
  local _cur="${!_var}"
  printf -v "$_var" '%s' "$(jq --arg s "$_val" '. + [$s]' <<<"$_cur")"
}

# Deep per-tool unit + dependency-graph discovery (v1.13.0 I7). Sourced here so
# nyann::discover_iac_units is available to ENRICH IAC_UNITS_JSON after a tool is
# classified — superseding the inline root-only globbing below with the fuller
# unit set (deep monorepo subdir discovery) and depends_on edges.
#
# Resolve our own dir from BASH_SOURCE rather than relying on _detect_dir: the
# normal chain (detect-stack.sh → detect-archetype.sh) sets _detect_dir, but the
# discover-iac-units.sh standalone guard sources THIS file directly (to reuse
# _iac_yaml_key), with no _detect_dir in scope. The `declare -F` guard also
# prevents a circular re-source in that standalone path (discover-iac-units.sh
# defines nyann::discover_iac_units before sourcing us).
if ! declare -F nyann::discover_iac_units >/dev/null 2>&1; then
  _iac_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=./discover-iac-units.sh
  source "${_iac_self_dir}/discover-iac-units.sh"
fi

nyann::detect_iac() {
  local target="${1-.}"
  IS_INFRA=0
  IAC_FRAMEWORK=""
  IAC_TOOL=""
  IAC_LANGUAGE=""
  IAC_UNITS_JSON='[]'
  IAC_LOCKFILES_JSON='[]'
  IAC_VAR_FILES_JSON='[]'

  # ---- 1. Helm (highest precedence) ----------------------------------------
  # Require corroboration (values.yaml or templates/) — a bare Chart.yaml at
  # the root is ambiguous (CD tools and packaging metadata also use that
  # name) and would misclassify an app repo as infra. Checked FIRST so a
  # chart whose templates/ holds k8s-looking manifests classifies as helm,
  # not kubernetes.
  if [[ -f "$target/Chart.yaml" ]] \
     && { [[ -f "$target/values.yaml" ]] || [[ -f "$target/values.yml" ]] || [[ -d "$target/templates" ]]; }; then
    IS_INFRA=1
    IAC_FRAMEWORK="helm"
    IAC_TOOL="helm"
    IAC_LANGUAGE="yaml"
    # Units (root chart + subcharts + dependencies) come from the deep
    # discovery pass — it supersedes the inline root-only globbing and adds
    # depends_on edges from each Chart.yaml `dependencies:`. Sets IAC_UNITS_JSON.
    nyann::discover_iac_units "$target" helm >/dev/null
    [[ -f "$target/Chart.lock" ]] && _iac_str_append IAC_LOCKFILES_JSON "Chart.lock"
    return 0
  fi

  # ---- 2. Kustomize --------------------------------------------------------
  # Beats bare-k8s. overlays/*/kustomization.yaml become overlay units.
  if [[ -f "$target/kustomization.yaml" || -f "$target/kustomization.yml" ]]; then
    IS_INFRA=1
    # framework is the profile-matching tag → "kubernetes" so the
    # kubernetes-app profile (which covers BOTH bare manifests and kustomize)
    # gets the +40 framework match for a kustomize repo. iac.tool stays the
    # precise "kustomize" (drives hook dispatch + per-unit logic).
    IAC_FRAMEWORK="kubernetes"
    IAC_TOOL="kustomize"
    IAC_LANGUAGE="yaml"
    # Overlay units (+ base depends_on edges) via deep discovery; supersedes
    # the inline overlays/* glob and walks monorepo subdir roots too.
    nyann::discover_iac_units "$target" kustomize >/dev/null
    return 0
  fi

  # ---- 3. Terraform --------------------------------------------------------
  # *.tf at root or under conventional IaC directories. We check both
  # immediate-children layouts (`modules/<name>/main.tf`) and the common
  # nested-under-a-top-level-dir layout
  # (`infrastructure/modules/<name>/main.tf`,
  # `terraform/environments/<env>/main.tf`).
  local _tf_hit=0
  if find "$target" -maxdepth 1 -name '*.tf' 2>/dev/null | head -1 | grep -q .; then
    _tf_hit=1
  else
    local d
    for d in modules stacks environments envs infrastructure terraform iac infra deploy; do
      [[ -d "$target/$d" ]] || continue
      # -maxdepth 5 catches both `infrastructure/main.tf` and
      # `infrastructure/modules/aws/networking/main.tf`. Going deeper costs
      # little because the directory list is short and find prunes hidden
      # dirs we don't care about (.git etc.) once they're skipped.
      if find "$target/$d" -maxdepth 5 -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | head -1 | grep -q .; then
        _tf_hit=1
        break
      fi
    done
  fi
  if [[ "$_tf_hit" == "1" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="terraform"
    IAC_TOOL="terraform"
    IAC_LANGUAGE="hcl"
    # I7: fill the full units[] graph (modules + environment stacks, with
    # depends_on edges from local `module "x" { source = "./.." }` references).
    # Sets IAC_UNITS_JSON. Lock + var files (NOT produced by discovery) are
    # still scanned inline below for downstream drift / plan subsystems.
    nyann::discover_iac_units "$target" terraform >/dev/null
    local _lf _vf
    while IFS= read -r _lf; do
      [[ -z "$_lf" ]] && continue
      _iac_str_append IAC_LOCKFILES_JSON "${_lf#"$target"/}"
    done < <(find "$target" -maxdepth 3 -name '.terraform.lock.hcl' -not -path '*/.terraform/*' 2>/dev/null)
    while IFS= read -r _vf; do
      [[ -z "$_vf" ]] && continue
      _iac_str_append IAC_VAR_FILES_JSON "${_vf#"$target"/}"
    done < <(find "$target" -maxdepth 4 \( -name '*.tfvars' -o -name '*.tfvars.json' \) -not -path '*/.terraform/*' 2>/dev/null)
    return 0
  fi

  # ---- 4. AWS CDK ----------------------------------------------------------
  # cdk.json present. Language inferred from the `app` field; stacks via glob
  # (NEVER `cdk list` — that needs bootstrapped credentials).
  if [[ -f "$target/cdk.json" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="cdk"
    IAC_TOOL="aws-cdk"
    local _app
    _app=$(jq -r '.app // empty' "$target/cdk.json" 2>/dev/null) || _app=""
    case "$_app" in
      *ts-node*|*.ts*|*tsx*)    IAC_LANGUAGE="typescript" ;;
      *python3*|*python*|*.py*) IAC_LANGUAGE="python" ;;
      *dotnet*)                 IAC_LANGUAGE="csharp" ;;
      "go "*|*" go "*|*"go run"*) IAC_LANGUAGE="go" ;;
      *)                        IAC_LANGUAGE="" ;;
    esac
    # Stack units via deep discovery: lib/*-stack.{ts,py,go,cs} + bin/*.{ts,py}
    # at the repo root AND conventional monorepo subdir roots (v1.13.0 I7 lifts
    # the prior root-only limit). Back-compat: root-only fixtures yield
    # identical path/name. CDK cross-stack edges live in program code and are
    # not parseable here, so stacks carry no depends_on. Sets IAC_UNITS_JSON.
    nyann::discover_iac_units "$target" aws-cdk >/dev/null
    return 0
  fi

  # ---- 5. Pulumi -----------------------------------------------------------
  # Pulumi.yaml → language from runtime:; stacks = Pulumi.*.yaml (exclude
  # Pulumi.yaml itself). Secure-config stack files feed the var_files scan.
  if [[ -f "$target/Pulumi.yaml" || -f "$target/Pulumi.yml" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="pulumi"
    IAC_TOOL="pulumi"
    local _proj="$target/Pulumi.yaml"
    [[ -f "$_proj" ]] || _proj="$target/Pulumi.yml"
    local _runtime
    _runtime=$(_iac_yaml_key "$_proj" runtime)
    case "$_runtime" in
      nodejs) IAC_LANGUAGE="typescript" ;;
      python) IAC_LANGUAGE="python" ;;
      go)     IAC_LANGUAGE="go" ;;
      dotnet) IAC_LANGUAGE="csharp" ;;
      *)      IAC_LANGUAGE="" ;;
    esac
    # Stack units via deep discovery (root + monorepo subdir roots). No
    # depends_on (StackReference lives in program code). Sets IAC_UNITS_JSON.
    nyann::discover_iac_units "$target" pulumi >/dev/null
    # var_files: each Pulumi.<stack>.yaml can carry secure: secrets, so record
    # it as a secret-scan target. Discovery emits units only, not var_files, so
    # this scan stays inline (root-level, matching the prior contract/tests).
    local _sf _base
    for _sf in "$target"/Pulumi.*.yaml "$target"/Pulumi.*.yml; do
      [[ -f "$_sf" ]] || continue
      _base="$(basename "$_sf")"
      # Skip the project manifest itself.
      [[ "$_base" == "Pulumi.yaml" || "$_base" == "Pulumi.yml" ]] && continue
      _iac_str_append IAC_VAR_FILES_JSON "$_base"
    done
    return 0
  fi

  # ---- 6. Ansible ----------------------------------------------------------
  # ansible.cfg OR roles/*/tasks/main.yml OR a top-level playbook
  # (*.yml/*.yaml with hosts: AND (tasks: OR roles:)). roles/* → role units,
  # top-level playbooks → playbook units. Checked before bare-k8s so a
  # playbook .yml is never misread as a k8s manifest.
  local _ansible_hit=0
  if [[ -f "$target/ansible.cfg" ]]; then
    _ansible_hit=1
  elif compgen -G "$target/roles/*/tasks/main.yml" >/dev/null 2>&1 \
       || compgen -G "$target/roles/*/tasks/main.yaml" >/dev/null 2>&1; then
    _ansible_hit=1
  else
    # Top-level playbook heuristic: a *.yml/*.yaml that has hosts: and a
    # tasks: or roles: key (the canonical play shape).
    local _pf
    for _pf in "$target"/*.yml "$target"/*.yaml; do
      [[ -f "$_pf" ]] || continue
      if grep -Eq '^[[:space:]]*-?[[:space:]]*hosts:' "$_pf" 2>/dev/null \
         && grep -Eq '^[[:space:]]*(tasks|roles):' "$_pf" 2>/dev/null; then
        _ansible_hit=1
        break
      fi
    done
  fi
  if [[ "$_ansible_hit" == "1" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="ansible"
    IAC_TOOL="ansible"
    IAC_LANGUAGE="yaml"
    # Role + playbook units via deep discovery (root + monorepo subdir roots),
    # with depends_on edges from role meta/main.yml `dependencies:` and each
    # playbook's referenced `roles:`. Sets IAC_UNITS_JSON.
    nyann::discover_iac_units "$target" ansible >/dev/null
    return 0
  fi

  # ---- 7. Bare Kubernetes manifests (lowest precedence) --------------------
  # *.yaml with apiVersion: AND kind:, no kustomization (handled above),
  # EXCLUDING CI yaml (.github/, .gitlab-ci.yml, other workflow files) so an
  # arbitrary YAML repo isn't misread as k8s. LAST so helm/kustomize/ansible
  # all claim first.
  local _kf _k8s_hit=0
  while IFS= read -r _kf; do
    [[ -z "$_kf" ]] && continue
    case "${_kf#"$target"/}" in
      .github/*|.gitlab-ci.yml|.gitlab-ci.yaml|.circleci/*) continue ;;
      */kustomization.yaml|*/kustomization.yml|kustomization.yaml|kustomization.yml) continue ;;
    esac
    if grep -Eq '^[[:space:]]*apiVersion:' "$_kf" 2>/dev/null \
       && grep -Eq '^[[:space:]]*kind:' "$_kf" 2>/dev/null; then
      _k8s_hit=1
      break
    fi
  done < <(find "$target" -maxdepth 3 \( -name '*.yaml' -o -name '*.yml' \) \
             -not -path '*/.git/*' 2>/dev/null)
  if [[ "$_k8s_hit" == "1" ]]; then
    IS_INFRA=1
    IAC_FRAMEWORK="kubernetes"
    IAC_TOOL="kubernetes"
    IAC_LANGUAGE="yaml"
    return 0
  fi

  return 1
}
