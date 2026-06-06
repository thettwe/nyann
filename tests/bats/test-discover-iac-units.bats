#!/usr/bin/env bats
# bin/detect-stack/discover-iac-units.sh — deep per-tool IaC unit + dependency
# graph discovery (v1.13.0 I7).
#
# Exercises the module via its STANDALONE entry point
#   bash bin/detect-stack/discover-iac-units.sh TARGET TOOL
# which sources _lib.sh + detect-iac.sh and invokes nyann::discover_iac_units,
# printing a single JSON array of units to stdout. The emit shape is:
#   { kind, path, name, version, depends_on? }   (depends_on OMITTED when empty)
#
# Coverage (per the I7 spec test plan):
#   - terraform module graph with cross-module `source =` edges
#   - terraform environments/* as kind=stack
#   - helm umbrella → subchart depends_on (Chart.yaml dependencies:)
#   - kustomize base + overlay edges (overlay → base)
#   - ansible role graph (role meta deps + playbook roles:)
#   - a CYCLIC dependency (warn + flat list, no abort / no hang)
#   - mixed / empty repo (noop → "[]")
#   - back-compat (single-module repo: same units, no spurious edges)
#   - the global IAC_UNITS_JSON side-effect contract

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DISCOVER="$REPO_ROOT/bin/detect-stack/discover-iac-units.sh"
  TMP="$(mktemp -d -t nyann-iacunits.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"   # resolve macOS /var → /private/var symlink
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}

teardown() { rm -rf "$TMP"; }

# --- helpers ---------------------------------------------------------------

# Run the module standalone against $REPO for TOOL ($1); stdout = units array.
_discover() { bash "$DISCOVER" "$REPO" "$1"; }

# ===========================================================================
# Terraform — module graph + environments-as-stacks
# ===========================================================================

@test "terraform: module graph with cross-module source edges" {
  mkdir -p "$REPO/modules/networking" "$REPO/modules/db"
  echo 'resource "null_resource" "net" {}' > "$REPO/modules/networking/main.tf"
  # db depends on networking via a local relative source.
  echo 'module "net" { source = "../networking" }' > "$REPO/modules/db/main.tf"

  out=$(_discover terraform)
  # Both module dirs surface as kind=module.
  echo "$out" | jq -e '[.[] | select(.kind=="module")] | length == 2'
  echo "$out" | jq -e 'any(.[]; .path=="modules/networking" and .name=="networking" and .kind=="module")'
  echo "$out" | jq -e 'any(.[]; .path=="modules/db" and .name=="db" and .kind=="module")'
  # The edge db → networking is recorded (resolved to the repo-relative path).
  echo "$out" | jq -e '.[] | select(.name=="db") | .depends_on | index("modules/networking")'
  # networking has no outgoing edge → depends_on key OMITTED entirely.
  echo "$out" | jq -e '.[] | select(.name=="networking") | has("depends_on") | not'
  # version is always null for terraform units.
  echo "$out" | jq -e '[.[].version] | all(. == null)'
}

@test "terraform: environments/* are kind=stack, modules/* are kind=module" {
  mkdir -p "$REPO/modules/db" "$REPO/environments/prod"
  echo 'resource "null_resource" "x" {}' > "$REPO/modules/db/main.tf"
  echo 'module "db" { source = "../../modules/db" }' > "$REPO/environments/prod/main.tf"

  out=$(_discover terraform)
  echo "$out" | jq -e '.[] | select(.path=="environments/prod") | .kind == "stack"'
  echo "$out" | jq -e '.[] | select(.path=="modules/db") | .kind == "module"'
  # The environment stack depends on the module it sources.
  echo "$out" | jq -e '.[] | select(.path=="environments/prod") | .depends_on | index("modules/db")'
}

@test "terraform: a root *.tf dir is a kind=stack named for the repo dir" {
  echo 'resource "null_resource" "root" {}' > "$REPO/main.tf"
  out=$(_discover terraform)
  echo "$out" | jq -e '.[] | select(.path==".") | .kind == "stack"'
  echo "$out" | jq -e '.[] | select(.path==".") | .name == "repo"'
}

@test "terraform: a remote/registry module source produces NO local edge" {
  mkdir -p "$REPO/environments/prod"
  cat > "$REPO/environments/prod/main.tf" <<'EOF'
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"
}
EOF
  out=$(_discover terraform)
  # Registry source is external → the unit carries no depends_on edge at all.
  echo "$out" | jq -e '.[] | select(.path=="environments/prod") | has("depends_on") | not'
}

# ===========================================================================
# Helm — umbrella → subchart depends_on
# ===========================================================================

@test "helm: umbrella Chart.yaml dependencies become depends_on edges" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: umbrella
version: 1.0.0
dependencies:
  - name: sub-a
    version: 0.4.0
  - name: sub-b
    version: 0.5.0
EOF
  echo 'replicaCount: 1' > "$REPO/values.yaml"
  mkdir -p "$REPO/charts/sub-a" "$REPO/charts/sub-b"
  printf 'apiVersion: v2\nname: sub-a\nversion: 0.4.0\n' > "$REPO/charts/sub-a/Chart.yaml"
  printf 'apiVersion: v2\nname: sub-b\nversion: 0.5.0\n' > "$REPO/charts/sub-b/Chart.yaml"

  out=$(_discover helm)
  # Root + 2 subcharts, all kind=chart.
  echo "$out" | jq -e 'length == 3'
  echo "$out" | jq -e '[.[].kind] | all(. == "chart")'
  # Umbrella depends_on both subchart names.
  echo "$out" | jq -e '.[] | select(.name=="umbrella") | .depends_on | index("sub-a")'
  echo "$out" | jq -e '.[] | select(.name=="umbrella") | .depends_on | index("sub-b")'
  # Subcharts carry no edges → key omitted, version surfaced.
  echo "$out" | jq -e '.[] | select(.name=="sub-a") | has("depends_on") | not'
  echo "$out" | jq -e '.[] | select(.name=="sub-a") | .version == "0.4.0"'
}

@test "helm: deep umbrella under deploy/ is discovered (lifts root-only limit)" {
  mkdir -p "$REPO/deploy/charts/svc"
  cat > "$REPO/deploy/Chart.yaml" <<'EOF'
apiVersion: v2
name: deployed
version: 2.0.0
EOF
  printf 'apiVersion: v2\nname: svc\nversion: 0.1.0\n' > "$REPO/deploy/charts/svc/Chart.yaml"
  out=$(_discover helm)
  echo "$out" | jq -e 'any(.[]; .path=="deploy" and .name=="deployed")'
  echo "$out" | jq -e 'any(.[]; .path=="deploy/charts/svc" and .name=="svc")'
}

# ===========================================================================
# Kustomize — base + overlay edges (only overlays/* emitted)
# ===========================================================================

@test "kustomize: overlays emitted with base depends_on edge; base not a unit" {
  mkdir -p "$REPO/base" "$REPO/overlays/dev" "$REPO/overlays/prod"
  printf 'apiVersion: apps/v1\nkind: Deployment\n' > "$REPO/base/deployment.yaml"
  printf 'resources:\n  - deployment.yaml\n' > "$REPO/base/kustomization.yaml"
  printf 'resources:\n  - ../../base\n' > "$REPO/overlays/dev/kustomization.yaml"
  printf 'resources:\n  - ../../base\n' > "$REPO/overlays/prod/kustomization.yaml"

  out=$(_discover kustomize)
  # Only the two overlays are units (base/root kustomizations are referenced).
  echo "$out" | jq -e 'length == 2'
  echo "$out" | jq -e '[.[].kind] | all(. == "overlay")'
  echo "$out" | jq -e '[.[].name] | sort == ["dev","prod"]'
  # Each overlay carries an edge to the resolved base dir.
  echo "$out" | jq -e '.[] | select(.name=="dev") | .depends_on | index("base")'
  echo "$out" | jq -e '.[] | select(.name=="prod") | .depends_on | index("base")'
}

# ===========================================================================
# Ansible — role graph (meta deps + playbook roles)
# ===========================================================================

@test "ansible: role meta dependencies + playbook roles become edges" {
  mkdir -p "$REPO/roles/web/tasks" "$REPO/roles/web/meta" \
           "$REPO/roles/common/tasks" "$REPO/roles/db/tasks"
  echo '- name: t' > "$REPO/roles/web/tasks/main.yml"
  echo '- name: t' > "$REPO/roles/common/tasks/main.yml"
  echo '- name: t' > "$REPO/roles/db/tasks/main.yml"
  cat > "$REPO/roles/web/meta/main.yml" <<'EOF'
dependencies:
  - common
  - db
EOF
  cat > "$REPO/site.yml" <<'EOF'
- hosts: all
  roles:
    - web
    - common
EOF

  out=$(_discover ansible)
  # 3 roles + 1 playbook.
  echo "$out" | jq -e '[.[] | select(.kind=="role")] | length == 3'
  echo "$out" | jq -e '[.[] | select(.kind=="playbook")] | length == 1'
  # web role depends on common + db (from meta/main.yml).
  echo "$out" | jq -e '.[] | select(.kind=="role" and .name=="web") | .depends_on | index("common")'
  echo "$out" | jq -e '.[] | select(.kind=="role" and .name=="web") | .depends_on | index("db")'
  # the play references web + common.
  echo "$out" | jq -e '.[] | select(.kind=="playbook" and .name=="site") | .depends_on | index("web")'
  echo "$out" | jq -e '.[] | select(.kind=="playbook" and .name=="site") | .depends_on | index("common")'
  # leaf roles carry no edges.
  echo "$out" | jq -e '.[] | select(.name=="common") | has("depends_on") | not'
}

# ===========================================================================
# Cycle safety — warn + flat list, never abort / hang
# ===========================================================================

@test "cyclic terraform deps: exits 0, warns, emits flat list with cycle broken" {
  mkdir -p "$REPO/modules/a" "$REPO/modules/b"
  echo 'module "b" { source = "../b" }' > "$REPO/modules/a/main.tf"
  echo 'module "a" { source = "../a" }' > "$REPO/modules/b/main.tf"

  # TERMINATION GUARD: the cycle breaker is an iterative DFS, so a cyclic graph
  # must COMPLETE (never hang). Bound it on the wall clock — a future recursion/
  # loop regression that fails to break the cycle would blow past this. The
  # whole module is pure filesystem + jq, well under a second normally.
  local _t0=$SECONDS
  run bash "$DISCOVER" "$REPO" terraform
  [ $(( SECONDS - _t0 )) -lt 10 ]                       # terminates promptly

  [ "$status" -eq 0 ]                                   # never aborts
  # stderr (folded into $output by `run`) carries the cycle warning.
  echo "$output" | grep -q "dependency cycle"

  # Both units still present (flat list intact).
  units=$(bash "$DISCOVER" "$REPO" terraform 2>/dev/null)
  echo "$units" | jq -e 'length == 2'
  echo "$units" | jq -e 'any(.[]; .name=="a")'
  echo "$units" | jq -e 'any(.[]; .name=="b")'
  # At most ONE of the two reciprocal edges survives → the graph is acyclic:
  # exactly one of a→b / b→a remains, the back-edge was dropped.
  edge_a=$(echo "$units" | jq '[.[] | select(.name=="a") | .depends_on // [] | .[]] | length')
  edge_b=$(echo "$units" | jq '[.[] | select(.name=="b") | .depends_on // [] | .[]] | length')
  [ "$(( edge_a + edge_b ))" -eq 1 ]
}

@test "self-referential module (source points at itself) drops the self-edge" {
  # A 1-node cycle (module sources its own dir) must not appear as depends_on.
  mkdir -p "$REPO/modules/loop"
  echo 'module "self" { source = "." }' > "$REPO/modules/loop/main.tf"
  out=$(_discover terraform)
  echo "$out" | jq -e '.[] | select(.name=="loop") | has("depends_on") | not'
}

@test "deep acyclic linear chain (~80 deep): all edges preserved, no depth warning" {
  # A legitimately deep but ACYCLIC chain m1 -> m2 -> ... -> m80. The cycle
  # breaker keys on PATH and only drops true back-edges, so the depth safety-net
  # must NOT fire and every one of the N-1 edges must survive. (Regression lock
  # for the old _IAC_MAX_CHAIN_DEPTH=64 cap that silently dropped a real edge.)
  local n=80 i j
  for i in $(seq 1 "$n"); do
    mkdir -p "$REPO/modules/m$i"
    if [ "$i" -lt "$n" ]; then
      j=$(( i + 1 ))
      echo "module \"next\" { source = \"../m$j\" }" > "$REPO/modules/m$i/main.tf"
    else
      echo 'resource "null_resource" "leaf" {}' > "$REPO/modules/m$i/main.tf"
    fi
  done

  run bash "$DISCOVER" "$REPO" terraform
  [ "$status" -eq 0 ]
  # No depth-cap warning and no (spurious) cycle warning anywhere on stderr.
  ! grep -q "exceeds max depth" <<<"$output"
  ! grep -q "dependency cycle" <<<"$output"

  units=$(bash "$DISCOVER" "$REPO" terraform 2>/dev/null)
  echo "$units" | jq -e 'length == 80'
  # Every non-leaf module keeps its single outgoing edge → N-1 = 79 edges total.
  echo "$units" | jq -e '([.[] | (.depends_on // []) | length] | add) == 79'
}

# ===========================================================================
# Name-collision graph integrity — node identity is PATH, not NAME
# (units sharing a `name` across scopes must not collapse / fabricate cycles)
# ===========================================================================

@test "name-collision DAG: same-named units with a non-cyclic edge → no cycle, edge kept" {
  # modules/vpc and services/vpc are BOTH named "vpc". services/vpc cleanly
  # depends on modules/vpc — a DAG, no cycle. Keying the graph on `name` (the
  # original bug) collapsed both into one node and fired a SPURIOUS cycle
  # warning while dropping the legit edge. Keying on PATH must keep it clean.
  mkdir -p "$REPO/modules/vpc" "$REPO/services/vpc"
  echo 'resource "null_resource" "m" {}' > "$REPO/modules/vpc/main.tf"
  echo 'module "vpc" { source = "../../modules/vpc" }' > "$REPO/services/vpc/main.tf"

  run bash "$DISCOVER" "$REPO" terraform
  [ "$status" -eq 0 ]
  # CRITICAL: NO cycle warning on a clean DAG.
  ! grep -q "dependency cycle" <<<"$output"

  units=$(bash "$DISCOVER" "$REPO" terraform 2>/dev/null)
  # Both same-named units are present as DISTINCT nodes (by path).
  echo "$units" | jq -e 'length == 2'
  echo "$units" | jq -e 'any(.[]; .path=="modules/vpc" and .name=="vpc")'
  echo "$units" | jq -e 'any(.[]; .path=="services/vpc" and .name=="vpc")'
  # The legit edge services/vpc → modules/vpc is PRESERVED (not dropped).
  echo "$units" | jq -e '.[] | select(.path=="services/vpc") | .depends_on | index("modules/vpc")'
  # modules/vpc has no outgoing edge → key omitted (no fabricated self-loop).
  echo "$units" | jq -e '.[] | select(.path=="modules/vpc") | has("depends_on") | not'
}

@test "name-collision resolution: a name-form edge binds to the correct (most-local) path" {
  # ansible role edges are emitted by NAME. Two roles named "svc" live in
  # different scopes: roles/svc (root) and deploy/roles/svc (local leaf).
  #   roles/svc (root)      meta dep -> web   (only one "web": deploy/roles/web)
  #   deploy/roles/web      meta dep -> svc
  # The "svc" edge from deploy/roles/web MUST bind to the MOST-LOCAL same-named
  # unit (deploy/roles/svc, a leaf) → the graph is acyclic. Mis-binding it to
  # the OTHER "svc" (roles/svc, which depends on web) would close a false cycle
  # roles/svc → web → svc → … and trigger a spurious warning. So "no cycle
  # warning" here is precisely the proof that the edge bound to the right path.
  mkdir -p "$REPO/roles/svc/tasks" "$REPO/roles/svc/meta" \
           "$REPO/deploy/roles/svc/tasks" \
           "$REPO/deploy/roles/web/tasks" "$REPO/deploy/roles/web/meta"
  echo '- name: t' > "$REPO/roles/svc/tasks/main.yml"
  echo '- name: t' > "$REPO/deploy/roles/svc/tasks/main.yml"
  echo '- name: t' > "$REPO/deploy/roles/web/tasks/main.yml"
  printf 'dependencies:\n  - web\n' > "$REPO/roles/svc/meta/main.yml"
  printf 'dependencies:\n  - svc\n' > "$REPO/deploy/roles/web/meta/main.yml"

  run bash "$DISCOVER" "$REPO" ansible
  [ "$status" -eq 0 ]
  # No cycle warning ⇒ "svc" resolved to deploy/roles/svc (leaf), not roles/svc.
  ! grep -q "dependency cycle" <<<"$output"

  units=$(bash "$DISCOVER" "$REPO" ansible 2>/dev/null)
  # All three distinct units present (two same-named "svc" kept apart by path).
  echo "$units" | jq -e 'length == 3'
  echo "$units" | jq -e '[.[] | select(.name=="svc")] | length == 2'
  # The two edges (emit shape: by name) are present and unchanged.
  echo "$units" | jq -e '.[] | select(.path=="roles/svc") | .depends_on == ["web"]'
  echo "$units" | jq -e '.[] | select(.path=="deploy/roles/web") | .depends_on == ["svc"]'
  # The local leaf deploy/roles/svc has no edge (it is the resolution target).
  echo "$units" | jq -e '.[] | select(.path=="deploy/roles/svc") | has("depends_on") | not'
}

@test "traversal: a source escaping the repo root is OMITTED (no fabricated edge)" {
  # ../../../../etc/passwd must NOT be clamped into a bogus repo-relative edge
  # like "etc/passwd"; an out-of-repo source simply yields no edge.
  mkdir -p "$REPO/modules/db"
  echo 'module "evil" { source = "../../../../etc/passwd" }' > "$REPO/modules/db/main.tf"
  out=$(_discover terraform)
  echo "$out" | jq -e '.[] | select(.name=="db") | has("depends_on") | not'
  # No fabricated path anywhere in the output.
  echo "$out" | jq -e '[.[] | (.depends_on // [])[]] | all(. | test("etc/passwd") | not)'
}

# ===========================================================================
# Mixed / empty / unknown — graceful "[]"
# ===========================================================================

@test "empty repo: emits []" {
  out=$(_discover terraform)
  [ "$out" = "[]" ]
}

@test "unknown tool: emits [] (no abort)" {
  echo 'resource "null_resource" "x" {}' > "$REPO/main.tf"
  run bash "$DISCOVER" "$REPO" frobnicate
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "bare kubernetes: emits [] (no discrete units, matches today)" {
  printf 'apiVersion: apps/v1\nkind: Deployment\n' > "$REPO/deployment.yaml"
  out=$(_discover kubernetes)
  [ "$out" = "[]" ]
}

@test "mixed repo (app sources alongside one tf module): only the tf unit surfaces for terraform" {
  # A repo with non-IaC noise plus a single terraform module. Calling the
  # terraform discovery yields just the module — app files are not units.
  mkdir -p "$REPO/src" "$REPO/modules/net"
  echo 'export const x = 1;' > "$REPO/src/index.ts"
  echo '{"name":"app"}' > "$REPO/package.json"
  echo 'resource "null_resource" "x" {}' > "$REPO/modules/net/main.tf"
  out=$(_discover terraform)
  echo "$out" | jq -e 'length == 1'
  echo "$out" | jq -e '.[0].path == "modules/net"'
}

# ===========================================================================
# Back-compat — single-unit repos emit the same units, no spurious edges
# ===========================================================================

@test "back-compat: single terraform module → same unit, no depends_on key" {
  mkdir -p "$REPO/modules/network"
  echo 'resource "null_resource" "x" {}' > "$REPO/modules/network/main.tf"
  out=$(_discover terraform)
  echo "$out" | jq -e 'length == 1'
  echo "$out" | jq -e '.[0] == {kind:"module", path:"modules/network", name:"network", version:null}'
}

@test "back-compat: single helm chart → byte-identical to legacy {kind,path,name,version}" {
  cat > "$REPO/Chart.yaml" <<'EOF'
apiVersion: v2
name: my-chart
version: 1.2.3
EOF
  echo 'replicaCount: 1' > "$REPO/values.yaml"
  out=$(_discover helm)
  # Exact object equality — no depends_on key, version present.
  echo "$out" | jq -e '. == [{kind:"chart", path:".", name:"my-chart", version:"1.2.3"}]'
}

@test "back-compat: single CDK stack → kind=stack, version null, NO depends_on" {
  mkdir -p "$REPO/lib"
  echo 'export class FooStack {}' > "$REPO/lib/foo-stack.ts"
  out=$(_discover aws-cdk)
  echo "$out" | jq -e '. == [{kind:"stack", path:"lib/foo-stack.ts", name:"foo-stack", version:null}]'
}

@test "back-compat: single pulumi stack → bare filename path, version null" {
  printf 'config: {}\n' > "$REPO/Pulumi.dev.yaml"
  out=$(_discover pulumi)
  echo "$out" | jq -e '. == [{kind:"stack", path:"Pulumi.dev.yaml", name:"dev", version:null}]'
}

# ===========================================================================
# Global side-effect contract — sets IAC_UNITS_JSON
# ===========================================================================

@test "nyann::discover_iac_units sets the global IAC_UNITS_JSON to the emitted array" {
  mkdir -p "$REPO/modules/net"
  echo 'resource "null_resource" "x" {}' > "$REPO/modules/net/main.tf"
  # Source the module (and its deps) in-process, call the function, then read
  # the global it must populate — the sibling-module convention detect-iac.sh
  # relies on to fold the result into the descriptor.
  out=$(bash -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/bin/_lib.sh"
    source "'"$REPO_ROOT"'/bin/detect-stack/detect-iac.sh"
    nyann::discover_iac_units "'"$REPO"'" terraform >/dev/null
    printf "%s" "$IAC_UNITS_JSON"
  ')
  echo "$out" | jq -e 'length == 1'
  echo "$out" | jq -e '.[0].path == "modules/net"'
}
