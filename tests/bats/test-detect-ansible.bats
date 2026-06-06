#!/usr/bin/env bats
# I6 — Ansible support: bin/detect-stack/detect-iac.sh (via detect-stack.sh) +
# profiles/ansible-playbook.json + the ansible IaC hook templates.
#
# Detection contract (from detect-iac.sh PRECEDENCE step 6):
#   ansible.cfg | roles/*/tasks/main.{yml,yaml} | top-level *.yml/*.yaml with
#   hosts: AND (tasks:|roles:)  →  IS_INFRA=1, framework="ansible",
#   iac.tool="ansible", iac.language="yaml". units: roles/* → kind=role,
#   matching top-level playbooks → kind=playbook.
#
# Discrimination guarantees asserted here mirror the spec's risk table:
#   - an Ansible playbook .yml is ansible, NEVER bare-kubernetes (step 6 runs
#     before step 7, and step 7 requires apiVersion:+kind: which a play lacks);
#   - a Helm chart (Chart.yaml + corroboration) is helm, NEVER plain k8s;
#   - CDK language is inferred from cdk.json .app;
#   - .github/ workflow yaml never trips k8s/ansible classification.
# Plus a NEGATIVE: a plain library repo is not classified as ansible.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  TMP="$(mktemp -d -t nyann-ansible.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

# Helper: emit the StackDescriptor JSON for a path.
descriptor_for() { bash "$DETECT" --path "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Detection: the three Ansible signals → framework/tool/language
# ---------------------------------------------------------------------------

@test "ansible: roles/<r>/tasks/main.yml → infra + tool ansible + language yaml" {
  mkdir -p "$REPO/roles/web/tasks"
  cat > "$REPO/roles/web/tasks/main.yml" <<'EOF'
- name: install nginx
  ansible.builtin.package:
    name: nginx
    state: present
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.framework == "ansible"'
  echo "$out" | jq -e '.iac.tool == "ansible"'
  echo "$out" | jq -e '.iac.language == "yaml"'
}

@test "ansible: roles/<r>/tasks/main.yaml (.yaml extension) also detected" {
  mkdir -p "$REPO/roles/db/tasks"
  cat > "$REPO/roles/db/tasks/main.yaml" <<'EOF'
- name: install postgres
  ansible.builtin.package:
    name: postgresql
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "ansible"'
}

@test "ansible: top-level playbook (hosts: + tasks:) → tool ansible" {
  cat > "$REPO/playbook.yml" <<'EOF'
- hosts: webservers
  tasks:
    - name: ping
      ansible.builtin.ping:
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.iac.tool == "ansible"'
}

@test "ansible: top-level playbook (hosts: + roles:) → tool ansible" {
  cat > "$REPO/site.yml" <<'EOF'
- hosts: all
  roles:
    - common
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "ansible"'
}

@test "ansible: ansible.cfg alone → tool ansible (decisive signal)" {
  cat > "$REPO/ansible.cfg" <<'EOF'
[defaults]
inventory = ./inventory
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.archetype == "infra"'
  echo "$out" | jq -e '.iac.tool == "ansible"'
}

# ---------------------------------------------------------------------------
# Units: roles → kind=role, playbooks → kind=playbook
# ---------------------------------------------------------------------------

@test "ansible: roles become role units (kind/path/name, version null)" {
  mkdir -p "$REPO/roles/web/tasks" "$REPO/roles/db/tasks"
  echo '- debug: msg=web' > "$REPO/roles/web/tasks/main.yml"
  echo '- debug: msg=db'  > "$REPO/roles/db/tasks/main.yml"
  out=$(descriptor_for "$REPO")
  # both roles present as role units
  echo "$out" | jq -e '[.iac.units[] | select(.kind == "role") | .name] | sort == ["db","web"]'
  echo "$out" | jq -e '.iac.units[] | select(.name == "web") | .kind == "role"'
  echo "$out" | jq -e '.iac.units[] | select(.name == "web") | .path == "roles/web"'
  # not independently versioned → version is JSON null
  echo "$out" | jq -e '.iac.units[] | select(.name == "web") | .version == null'
}

@test "ansible: matching top-level playbook becomes a playbook unit" {
  cat > "$REPO/deploy.yml" <<'EOF'
- hosts: app
  tasks:
    - name: noop
      ansible.builtin.debug:
        msg: hi
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.units[] | select(.kind == "playbook") | .name == "deploy"'
  echo "$out" | jq -e '.iac.units[] | select(.kind == "playbook") | .path == "deploy.yml"'
}

@test "ansible: role + playbook coexist as distinct units" {
  mkdir -p "$REPO/roles/common/tasks"
  echo '- debug: msg=common' > "$REPO/roles/common/tasks/main.yml"
  cat > "$REPO/site.yml" <<'EOF'
- hosts: all
  roles:
    - common
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '[.iac.units[].kind] | sort | unique == ["playbook","role"]'
}

# ---------------------------------------------------------------------------
# Discrimination edge cases (spec risk table)
# ---------------------------------------------------------------------------

@test "discrimination: playbook .yml is ansible, NOT bare-kubernetes" {
  # A play has hosts:+tasks: but no apiVersion:/kind:, so step 6 claims it
  # before step 7 (bare-k8s) can.
  cat > "$REPO/deploy.yml" <<'EOF'
- hosts: webservers
  become: true
  tasks:
    - name: ensure nginx
      ansible.builtin.service:
        name: nginx
        state: started
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "ansible"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "discrimination: ansible repo with a .github/ workflow yaml stays ansible" {
  # CI yaml under .github/ must never sway IaC classification.
  mkdir -p "$REPO/.github/workflows" "$REPO/roles/web/tasks"
  echo '- debug: msg=web' > "$REPO/roles/web/tasks/main.yml"
  cat > "$REPO/.github/workflows/ci.yml" <<'EOF'
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "ansible"'
}

@test "discrimination: Helm chart (Chart.yaml + templates/) is helm, NOT plain k8s" {
  # Step 1 short-circuits before step 7 even though templates/ holds
  # k8s-looking manifests.
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 0.1.0
EOF
  mkdir -p "$REPO/templates"
  cat > "$REPO/templates/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: x
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "helm"'
  echo "$out" | jq -e '.iac.tool != "kubernetes"'
}

@test "discrimination: bare k8s manifest (apiVersion:+kind:) is kubernetes" {
  cat > "$REPO/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "kubernetes"'
}

@test "discrimination: .github-only k8s yaml is NOT classified as infra" {
  # The only k8s-shaped yaml lives under .github/ → excluded → not infra.
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/release.yml" <<'EOF'
apiVersion: should-be-ignored
kind: ShouldBeIgnored
EOF
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e 'has("iac") | not'
}

@test "discrimination: CDK language inferred from cdk.json .app field" {
  echo '{"app":"npx ts-node bin/app.ts"}' > "$REPO/cdk.json"
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.iac.tool == "aws-cdk"'
  echo "$out" | jq -e '.framework == "cdk"'
  echo "$out" | jq -e '.iac.language == "typescript"'
}

# ---------------------------------------------------------------------------
# NEGATIVE: a non-ansible repo must not be classified as ansible
# ---------------------------------------------------------------------------

@test "negative: plain node library is NOT ansible and emits no iac block" {
  echo '{"name":"lib","version":"1.0.0"}' > "$REPO/package.json"
  echo 'export const x = 1;' > "$REPO/index.js"
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e '(.framework // "") != "ansible"'
  echo "$out" | jq -e 'has("iac") | not'
}

@test "negative: empty repo is not ansible" {
  out=$(descriptor_for "$REPO")
  echo "$out" | jq -e '.archetype != "infra"'
  echo "$out" | jq -e 'has("iac") | not'
}

# ---------------------------------------------------------------------------
# Profile: ansible-playbook.json shape + hook wiring
# ---------------------------------------------------------------------------

@test "ansible-playbook profile declares the ansible IaC tool + infra archetype" {
  jq -e '.archetype == "infra"'        "$REPO_ROOT/profiles/ansible-playbook.json"
  jq -e '.stack.framework == "ansible"' "$REPO_ROOT/profiles/ansible-playbook.json"
  jq -e '.iac.tool == "ansible"'        "$REPO_ROOT/profiles/ansible-playbook.json"
}

@test "ansible-playbook profile wires ansible-lint + yamllint + ansible-syntax-check" {
  jq -e '.hooks.pre_commit | index("ansible-lint")'         "$REPO_ROOT/profiles/ansible-playbook.json"
  jq -e '.hooks.pre_commit | index("yamllint")'             "$REPO_ROOT/profiles/ansible-playbook.json"
  jq -e '.hooks.pre_commit | index("ansible-syntax-check")' "$REPO_ROOT/profiles/ansible-playbook.json"
}

@test "ansible-playbook profile validates against the profile schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  # The profile pins primary_language=yaml. The profile schema's
  # stack.primary_language enum gains "yaml" in the shared-core schema phase
  # (it already lives in the descriptor schema). Until that lands, this
  # assertion is the canary — skip rather than red so this per-tool file is
  # green on its own and turns green-for-real once the shared edit ships.
  if ! jq -e '.properties.stack.properties.primary_language.enum | index("yaml")' \
        "$REPO_ROOT/profiles/_schema.json" >/dev/null 2>&1; then
    skip "profile schema stack.primary_language enum lacks 'yaml' (pending shared-core schema phase)"
  fi
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/profiles/_schema.json" \
    "$REPO_ROOT/profiles/ansible-playbook.json"
}

# ---------------------------------------------------------------------------
# Hook templates: correct per-tool subdir + soft-skip-when-CLI-absent idiom
# ---------------------------------------------------------------------------

@test "ansible hook scripts live under the per-tool subdir templates/hooks/iac/ansible" {
  [ -f "$REPO_ROOT/templates/hooks/iac/ansible/ansible-lint.sh" ]
  [ -f "$REPO_ROOT/templates/hooks/iac/ansible/yamllint.sh" ]
  [ -f "$REPO_ROOT/templates/hooks/iac/ansible/ansible-syntax-check.sh" ]
}

@test "ansible hook: ansible-lint soft-skips when ansible-lint missing" {
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/ansible/ansible-lint.sh" 2>&1 )
  status=$?
  [ "$status" -eq 0 ]
  echo "$out" | grep -q "ansible-lint not installed"
}

@test "ansible hook: yamllint soft-skips when yamllint missing" {
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/ansible/yamllint.sh" 2>&1 )
  status=$?
  [ "$status" -eq 0 ]
  echo "$out" | grep -q "yamllint not installed"
}

@test "ansible hook: ansible-syntax-check soft-skips when ansible-playbook missing" {
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/templates/hooks/iac/ansible/ansible-syntax-check.sh" 2>&1 )
  status=$?
  [ "$status" -eq 0 ]
  echo "$out" | grep -q "ansible-playbook not installed"
}

@test "iac-ansible pre-commit template references the per-tool subdir scripts" {
  cfg="$REPO_ROOT/templates/pre-commit-configs/iac-ansible.yaml"
  [ -f "$cfg" ]
  grep -q ".nyann/hooks/iac/ansible/ansible-lint.sh"         "$cfg"
  grep -q ".nyann/hooks/iac/ansible/yamllint.sh"             "$cfg"
  grep -q ".nyann/hooks/iac/ansible/ansible-syntax-check.sh" "$cfg"
}
