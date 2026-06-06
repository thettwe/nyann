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

# _iac_unit_append JSON_VAR KIND PATH NAME [VERSION] — append a unit object to
# the named jq-array variable. VERSION omitted/empty → JSON null.
_iac_unit_append() {
  local _var="$1" _kind="$2" _path="$3" _name="$4" _ver="${5-}"
  local _ver_json='null'
  [[ -n "$_ver" ]] && _ver_json="$(jq -n --arg v "$_ver" '$v')"
  local _cur="${!_var}"
  printf -v "$_var" '%s' \
    "$(jq --arg k "$_kind" --arg p "$_path" --arg n "$_name" --argjson v "$_ver_json" \
        '. + [{kind:$k, path:$p, name:$n, version:$v}]' <<<"$_cur")"
}

# _iac_str_append JSON_VAR VALUE — append a string to the named jq-array var.
_iac_str_append() {
  local _var="$1" _val="$2"
  local _cur="${!_var}"
  printf -v "$_var" '%s' "$(jq --arg s "$_val" '. + [$s]' <<<"$_cur")"
}

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
    # version / appVersion from Chart.yaml; subcharts under charts/*/Chart.yaml.
    local _chart_ver
    _chart_ver=$(_iac_yaml_key "$target/Chart.yaml" version)
    local _chart_name
    _chart_name=$(_iac_yaml_key "$target/Chart.yaml" name)
    [[ -z "$_chart_name" ]] && _chart_name="$(basename "$target")"
    _iac_unit_append IAC_UNITS_JSON chart "." "$_chart_name" "$_chart_ver"
    local _sub
    for _sub in "$target"/charts/*/Chart.yaml; do
      [[ -f "$_sub" ]] || continue
      local _sub_dir _sub_rel _sub_name _sub_ver
      _sub_dir="$(dirname "$_sub")"
      _sub_rel="charts/$(basename "$_sub_dir")"
      _sub_name=$(_iac_yaml_key "$_sub" name)
      [[ -z "$_sub_name" ]] && _sub_name="$(basename "$_sub_dir")"
      _sub_ver=$(_iac_yaml_key "$_sub" version)
      _iac_unit_append IAC_UNITS_JSON chart "$_sub_rel" "$_sub_name" "$_sub_ver"
    done
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
    local _ov
    for _ov in "$target"/overlays/*/kustomization.yaml "$target"/overlays/*/kustomization.yml; do
      [[ -f "$_ov" ]] || continue
      local _ov_dir _ov_rel _ov_name
      _ov_dir="$(dirname "$_ov")"
      _ov_name="$(basename "$_ov_dir")"
      _ov_rel="overlays/$_ov_name"
      _iac_unit_append IAC_UNITS_JSON overlay "$_ov_rel" "$_ov_name"
    done
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
    # Lock + var files for downstream drift / plan subsystems. I7 fills the
    # full units[] graph; here we record the obvious top-level signals.
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
    # Glob-based stack discovery: lib/*-stack.{ts,py,go,cs} + bin/*.{ts,py}.
    # Iterate the glob expansion DIRECTLY (no inner `for _f in $_g`): glob
    # results are not word-split, so a stack filename containing spaces is
    # preserved as one word; an unmatched pattern stays literal and is
    # skipped by the `-f` guard. (Detection is repo-ROOT only here; deep
    # monorepo subdir discovery is v1.13.0 I7's job — see docs/roadmap.)
    local _f _name
    for _f in "$target"/lib/*-stack.ts "$target"/lib/*-stack.py \
              "$target"/lib/*-stack.go "$target"/lib/*-stack.cs \
              "$target"/bin/*.ts "$target"/bin/*.py; do
      [[ -f "$_f" ]] || continue
      _name="$(basename "$_f")"
      _name="${_name%.*}"
      _iac_unit_append IAC_UNITS_JSON stack "${_f#"$target"/}" "$_name"
    done
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
    # Stacks: Pulumi.<stack>.yaml (exclude the project file). Each stack
    # config can carry secure: secrets, so record it as a var-file too.
    local _sf _base _stack
    for _sf in "$target"/Pulumi.*.yaml "$target"/Pulumi.*.yml; do
      [[ -f "$_sf" ]] || continue
      _base="$(basename "$_sf")"
      # Skip the project manifest itself.
      [[ "$_base" == "Pulumi.yaml" || "$_base" == "Pulumi.yml" ]] && continue
      _stack="${_base#Pulumi.}"
      _stack="${_stack%.yaml}"
      _stack="${_stack%.yml}"
      _iac_unit_append IAC_UNITS_JSON stack "$_base" "$_stack"
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
    local _rd _rname
    for _rd in "$target"/roles/*/; do
      [[ -d "$_rd" ]] || continue
      _rname="$(basename "$_rd")"
      _iac_unit_append IAC_UNITS_JSON role "roles/$_rname" "$_rname"
    done
    local _pb _pbname
    for _pb in "$target"/*.yml "$target"/*.yaml; do
      [[ -f "$_pb" ]] || continue
      if grep -Eq '^[[:space:]]*-?[[:space:]]*hosts:' "$_pb" 2>/dev/null \
         && grep -Eq '^[[:space:]]*(tasks|roles):' "$_pb" 2>/dev/null; then
        _pbname="$(basename "$_pb")"
        _pbname="${_pbname%.*}"
        _iac_unit_append IAC_UNITS_JSON playbook "$(basename "$_pb")" "$_pbname"
      fi
    done
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
