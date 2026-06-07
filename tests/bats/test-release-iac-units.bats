#!/usr/bin/env bats
# test-release-iac-units.bats — v1.13.0 I10: per-module / per-chart versioning
# in release. Extends the v1.11.0 workspace-release machinery to IaC units.
#
# Coverage:
#   - Helm Chart.yaml `version:` bump (yaml-version-key) + appVersion mirror.
#   - Terraform module VERSION-file bump (text-version).
#   - Per-kind tag conventions: chart -> `<name>-X.Y.Z`; module/stack ->
#     path-scoped `<path>/vX.Y.Z`.
#   - Multi-unit batch release (one commit, tags after, point at it).
#   - TOPO-ordered release via depends_on (module tagged before dependent chart).
#   - Changed-only units released (unchanged units skipped/noop).
#   - Tag-collision: a unit tag must never collide with a repo-wide vX.Y.Z, and
#     an exact duplicate tag is rejected.
#   - depends_on cycle: best-effort order, warns, never hangs/aborts.
#   - Back-compat: a code monorepo workspace release is byte-for-byte unchanged.

setup() {
  export RELEASE="${BATS_TEST_DIRNAME}/../../bin/release.sh"
  export WS_RELEASE="${BATS_TEST_DIRNAME}/../../bin/release/release-workspace.sh"
  export WS_DETECT="${BATS_TEST_DIRNAME}/../../bin/release/detect-workspace-changes.sh"
  export BUMP="${BATS_TEST_DIRNAME}/../../bin/release/bump-manifests.sh"
  export TOPO="${BATS_TEST_DIRNAME}/../../bin/release/topo-order-units.sh"
  TMP="$(mktemp -d -t nyann-rel-iac.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  export TMP
}

teardown() { rm -rf "$TMP"; }

# --- helpers -----------------------------------------------------------------

# A repo with a terraform module (modules/vpc, VERSION file) and a Helm chart
# (charts/app, Chart.yaml). Each unit gets a post-root commit so the path-diff
# finds a change.
make_iac_repo() {
  local d="$TMP/iac-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$d/modules/vpc" "$d/charts/app"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"

  echo 'resource "null_resource" "vpc" {}' > "$d/modules/vpc/main.tf"
  echo '1.2.0' > "$d/modules/vpc/VERSION"
  cat > "$d/charts/app/Chart.yaml" <<'EOF'
apiVersion: v2
name: app
version: 0.3.0
appVersion: "1.0.0"
EOF
  git -C "$d" add -A
  git -C "$d" commit -qm "feat: scaffold module + chart"

  # Post-root change to each unit so both are 'changed'.
  echo '# touch' >> "$d/modules/vpc/main.tf"
  echo '# touch' >> "$d/charts/app/Chart.yaml"
  git -C "$d" add -A
  git -C "$d" commit -qm "fix(infra): touch module and chart"

  echo "$d"
}

# A code monorepo (mirrors test-release-workspace.bats' make_monorepo) for the
# back-compat assertion.
make_code_monorepo() {
  local d="$TMP/mono-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$d/packages/core"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"
  echo '{"name":"core","version":"0.1.0"}' > "$d/packages/core/package.json"
  echo 'console.log("core")' > "$d/packages/core/index.ts"
  git -C "$d" add -A
  git -C "$d" commit -qm "feat(core): initial core package"
  echo 'updated' >> "$d/packages/core/index.ts"
  git -C "$d" add -A
  git -C "$d" commit -qm "fix(core): fix core bug"
  echo "$d"
}

# ────────────────────────────────────────────────────────────────────
# bump-manifests.sh — yaml-version-key (Helm Chart.yaml)
# ────────────────────────────────────────────────────────────────────

@test "bump yaml-version-key: bumps Chart.yaml version, mirrors appVersion" {
  repo=$(make_iac_repo)
  prof="$TMP/prof-helm-$BATS_TEST_NUMBER.json"
  cat > "$prof" <<'JSON'
{"name":"t","schemaVersion":1,"release":{"bump_files":[
  {"path":"charts/app/Chart.yaml","format":"yaml-version-key","app_version":true}
]}}
JSON
  out=$(bash "$BUMP" --mode compute --target "$repo" --version 0.4.0 --profile "$prof" 2>/dev/null)
  echo "$out" | jq -e '.bumped_files[0].action == "bumped"'
  echo "$out" | jq -e '.bumped_files[0].from_version == "0.3.0"'
  echo "$out" | jq -e '.plan[0].payload == "version+appVersion"'

  echo "$out" > "$TMP/plan-helm.json"
  bash "$BUMP" --mode apply --target "$repo" --version 0.4.0 --plan-file "$TMP/plan-helm.json"
  # chart version bumped; appVersion mirrored to the release tag.
  grep -qx 'version: 0.4.0' "$repo/charts/app/Chart.yaml"
  grep -qx 'appVersion: "0.4.0"' "$repo/charts/app/Chart.yaml"
}

@test "bump yaml-version-key: without app_version leaves appVersion untouched" {
  repo=$(make_iac_repo)
  prof="$TMP/prof-helm2-$BATS_TEST_NUMBER.json"
  cat > "$prof" <<'JSON'
{"name":"t","schemaVersion":1,"release":{"bump_files":[
  {"path":"charts/app/Chart.yaml","format":"yaml-version-key"}
]}}
JSON
  bash "$BUMP" --mode compute --target "$repo" --version 0.4.0 --profile "$prof" 2>/dev/null > "$TMP/plan2.json"
  bash "$BUMP" --mode apply --target "$repo" --version 0.4.0 --plan-file "$TMP/plan2.json"
  grep -qx 'version: 0.4.0' "$repo/charts/app/Chart.yaml"
  # appVersion must stay at its original value.
  grep -qx 'appVersion: "1.0.0"' "$repo/charts/app/Chart.yaml"
}

@test "bump yaml-version-key: unchanged when already at target version" {
  repo=$(make_iac_repo)
  prof="$TMP/prof-helm3-$BATS_TEST_NUMBER.json"
  cat > "$prof" <<'JSON'
{"name":"t","schemaVersion":1,"release":{"bump_files":[
  {"path":"charts/app/Chart.yaml","format":"yaml-version-key"}
]}}
JSON
  out=$(bash "$BUMP" --mode compute --target "$repo" --version 0.3.0 --profile "$prof" 2>/dev/null)
  echo "$out" | jq -e '.bumped_files[0].action == "unchanged"'
  echo "$out" | jq -e '.plan | length == 0'
}

# ────────────────────────────────────────────────────────────────────
# bump-manifests.sh — text-version (terraform module VERSION file)
# ────────────────────────────────────────────────────────────────────

@test "bump text-version: bumps terraform module VERSION file" {
  repo=$(make_iac_repo)
  prof="$TMP/prof-tf-$BATS_TEST_NUMBER.json"
  cat > "$prof" <<'JSON'
{"name":"t","schemaVersion":1,"release":{"bump_files":[
  {"path":"modules/vpc/VERSION","format":"text-version"}
]}}
JSON
  out=$(bash "$BUMP" --mode compute --target "$repo" --version 1.3.0 --profile "$prof" 2>/dev/null)
  echo "$out" | jq -e '.bumped_files[0].action == "bumped"'
  echo "$out" | jq -e '.bumped_files[0].from_version == "1.2.0"'

  echo "$out" > "$TMP/plan-tf.json"
  bash "$BUMP" --mode apply --target "$repo" --version 1.3.0 --plan-file "$TMP/plan-tf.json"
  [ "$(cat "$repo/modules/vpc/VERSION")" = "1.3.0" ]
}

@test "bump text-version: TOCTOU digest mismatch refuses to apply" {
  repo=$(make_iac_repo)
  cat > "$TMP/plan-bad.json" <<'JSON'
{"bumped_files":[],"plan":[{"path":"modules/vpc/VERSION","format":"text-version","payload":"text","digest":"deadbeef"}]}
JSON
  run bash "$BUMP" --mode apply --target "$repo" --version 1.3.0 --plan-file "$TMP/plan-bad.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "digest mismatch"
}

# ────────────────────────────────────────────────────────────────────
# release-workspace.sh — per-kind tag conventions + unit_kind
# ────────────────────────────────────────────────────────────────────

@test "release-workspace chart: tag is <name>-<version> + unit_kind=chart" {
  repo=$(make_iac_repo)
  out=$(bash "$WS_RELEASE" --target "$repo" --workspace charts/app --version 0.4.0 \
    --kind chart --name app --dry-run 2>/dev/null)
  echo "$out" | jq -e '.tag == "app-0.4.0"'
  echo "$out" | jq -e '.unit_kind == "chart"'
  echo "$out" | jq -e '.status == "preview"'
}

@test "release-workspace module: tag is path-scoped <path>/v<version>" {
  repo=$(make_iac_repo)
  out=$(bash "$WS_RELEASE" --target "$repo" --workspace modules/vpc --version 1.3.0 \
    --kind module --name vpc --dry-run 2>/dev/null)
  echo "$out" | jq -e '.tag == "modules/vpc/v1.3.0"'
  echo "$out" | jq -e '.unit_kind == "module"'
}

@test "release-workspace chart: actually tags chart-name-version" {
  repo=$(make_iac_repo)
  out=$(bash "$WS_RELEASE" --target "$repo" --workspace charts/app --version 0.4.0 \
    --kind chart --name app --yes 2>/dev/null)
  echo "$out" | jq -e '.status == "released"'
  # release-workspace writes the changelog but does NOT tag; the tag string
  # it RETURNS is what release.sh applies. Assert the returned tag + changelog.
  echo "$out" | jq -e '.tag == "app-0.4.0"'
  [ -f "$repo/charts/app/CHANGELOG.md" ]
  grep -q '0.4.0' "$repo/charts/app/CHANGELOG.md"
}

@test "release-workspace: code workspace (no --kind) is unchanged — core@x, no unit_kind" {
  repo=$(make_code_monorepo)
  out=$(bash "$WS_RELEASE" --target "$repo" --workspace packages/core --version 1.0.0 --dry-run 2>/dev/null)
  echo "$out" | jq -e '.tag == "core@1.0.0"'
  echo "$out" | jq -e 'has("unit_kind") | not'
}

# ────────────────────────────────────────────────────────────────────
# Tag-collision guards
# ────────────────────────────────────────────────────────────────────

@test "release-workspace: unit tag colliding with repo-wide vX.Y.Z is rejected" {
  repo=$(make_iac_repo)
  # An explicit --tag-prefix 'v' would collapse to v1.3.0 == repo-wide tag.
  run bash "$WS_RELEASE" --target "$repo" --workspace modules/vpc --version 1.3.0 \
    --kind module --tag-prefix "v"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "collides with the repo-wide release tag namespace"
}

@test "release-workspace: exact-duplicate unit tag is rejected" {
  repo=$(make_iac_repo)
  # Pre-create the chart tag so the rev-parse guard fires.
  git -C "$repo" tag "app-0.4.0"
  run bash "$WS_RELEASE" --target "$repo" --workspace charts/app --version 0.4.0 \
    --kind chart --name app
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "already exists"
}

@test "release-workspace: chart name starting with '-' fails cleanly (not a git-option abort)" {
  repo=$(make_iac_repo)
  # A Helm Chart.yaml `name: -foo` (detection reads it; the profile schema
  # forbids it) must NOT make `git tag --list "-foo-*"` parse the prefix as a
  # git option (rc 129). The leading-dash guard dies cleanly first.
  run bash "$WS_RELEASE" --target "$repo" --workspace charts/app --version 0.4.0 \
    --kind chart --name "-foo"
  [ "$status" -ne 0 ]
  [ "$status" -ne 129 ]
  echo "$output" | grep -F "starts with '-'"
}

@test "release-workspace: a unit name with shell metacharacters is not executed" {
  repo=$(make_iac_repo)
  : > "$repo/CANARY"
  # The name flows into the tag string only; it must never be evaluated.
  run bash "$WS_RELEASE" --target "$repo" --workspace charts/app --version 0.4.0 \
    --kind chart --name 'x$(rm -f CANARY)' --dry-run
  [ -f "$repo/CANARY" ]
}

# ────────────────────────────────────────────────────────────────────
# topo-order-units.sh
# ────────────────────────────────────────────────────────────────────

@test "topo-order-units: dependency-first order (deps before dependents)" {
  units='[
    {"kind":"module","path":"modules/db","name":"db","depends_on":["networking"]},
    {"kind":"chart","path":"charts/app","name":"app","depends_on":["modules/db"]},
    {"kind":"module","path":"modules/networking","name":"networking"}
  ]'
  out=$(echo "$units" | bash "$TOPO")
  # networking has no deps -> first; db depends on networking; app depends on db.
  [ "$(echo "$out" | sed -n 1p)" = "modules/networking" ]
  [ "$(echo "$out" | sed -n 2p)" = "modules/db" ]
  [ "$(echo "$out" | sed -n 3p)" = "charts/app" ]
}

@test "topo-order-units: cycle does not hang, warns, emits all nodes" {
  units='[
    {"kind":"module","path":"modules/a","name":"a","depends_on":["b"]},
    {"kind":"module","path":"modules/b","name":"b","depends_on":["a"]}
  ]'
  _t0=$SECONDS
  run bash -c "echo '$units' | bash '$TOPO'"
  [ "$status" -eq 0 ]
  [ $(( SECONDS - _t0 )) -lt 10 ]
  echo "$output" | grep -q "modules/a"
  echo "$output" | grep -q "modules/b"
}

# ────────────────────────────────────────────────────────────────────
# release.sh --iac-units — multi-unit batch + topo-ordered integration
# ────────────────────────────────────────────────────────────────────

# A 3-unit DAG: charts/app -> modules/db -> modules/networking.
make_dag_repo() {
  local d="$TMP/dag-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$d/modules/networking" "$d/modules/db" "$d/charts/app"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test"
  git -C "$d" config user.name "test"
  echo 'resource "null_resource" "net" {}' > "$d/modules/networking/main.tf"
  echo 'module "net" { source = "../networking" }' > "$d/modules/db/main.tf"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$d/charts/app/Chart.yaml"
  git -C "$d" add -A
  git -C "$d" commit -qm "feat: scaffold DAG"
  echo '#x' >> "$d/modules/networking/main.tf"
  echo '#y' >> "$d/modules/db/main.tf"
  echo '#z' >> "$d/charts/app/Chart.yaml"
  git -C "$d" add -A
  git -C "$d" commit -qm "feat(units): touch all units"
  cat > "$d/units.json" <<'JSON'
[
  {"kind":"module","path":"modules/db","name":"db","version":null,"depends_on":["networking"]},
  {"kind":"chart","path":"charts/app","name":"app","version":"0.1.0","depends_on":["modules/db"]},
  {"kind":"module","path":"modules/networking","name":"networking","version":null}
]
JSON
  echo "$d"
}

@test "release.sh --iac-units: multi-unit batch release tags all units" {
  repo=$(make_dag_repo)
  out=$(bash "$RELEASE" --target "$repo" --version 1.0.0 \
    --iac-units "$repo/units.json" --batch-commit --yes 2>/dev/null)
  echo "$out" | jq -e '.workspaces | length == 3'
  echo "$out" | jq -e '[.workspaces[] | select(.status == "released")] | length == 3'
  git -C "$repo" rev-parse --verify "refs/tags/modules/networking/v1.0.0" >/dev/null 2>&1
  git -C "$repo" rev-parse --verify "refs/tags/modules/db/v1.0.0" >/dev/null 2>&1
  git -C "$repo" rev-parse --verify "refs/tags/app-1.0.0" >/dev/null 2>&1
}

@test "release.sh --iac-units: TOPO order — module tagged before dependent chart" {
  repo=$(make_dag_repo)
  out=$(bash "$RELEASE" --target "$repo" --version 1.0.0 \
    --iac-units "$repo/units.json" --batch-commit --yes 2>/dev/null)
  # Result array order reflects release order: networking, db, then app.
  echo "$out" | jq -e '.workspaces[0].workspace == "modules/networking"'
  echo "$out" | jq -e '.workspaces[1].workspace == "modules/db"'
  echo "$out" | jq -e '.workspaces[2].workspace == "charts/app"'
  echo "$out" | jq -e '.workspaces[2].unit_kind == "chart"'
}

@test "release.sh --iac-units: batch tags point at the commit containing changelogs" {
  repo=$(make_dag_repo)
  bash "$RELEASE" --target "$repo" --version 1.0.0 \
    --iac-units "$repo/units.json" --batch-commit --yes 2>/dev/null
  # Every unit tag must resolve to the SAME batch commit that holds all changelogs.
  net_sha=$(git -C "$repo" rev-parse "modules/networking/v1.0.0^{commit}")
  app_sha=$(git -C "$repo" rev-parse "app-1.0.0^{commit}")
  [ "$net_sha" = "$app_sha" ]
  git -C "$repo" show --stat "$net_sha" | grep -q "modules/networking/CHANGELOG.md"
  git -C "$repo" show --stat "$net_sha" | grep -q "charts/app/CHANGELOG.md"
}

@test "release.sh --iac-units: changed-only — unchanged unit is skipped (noop, not tagged)" {
  repo="$TMP/changed-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$repo/modules/a" "$repo/modules/b"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@test"
  git -C "$repo" config user.name "test"
  echo 'resource "null_resource" "a" {}' > "$repo/modules/a/main.tf"
  echo 'resource "null_resource" "b" {}' > "$repo/modules/b/main.tf"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "feat: init both modules"
  # Pre-tag both so 'from' is that scoped tag; then change ONLY module a.
  git -C "$repo" tag "modules/a/v0.9.0"
  git -C "$repo" tag "modules/b/v0.9.0"
  echo '# changed' >> "$repo/modules/a/main.tf"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "fix(a): change only module a"
  cat > "$repo/units.json" <<'JSON'
[
  {"kind":"module","path":"modules/a","name":"a","version":null},
  {"kind":"module","path":"modules/b","name":"b","version":null}
]
JSON
  out=$(bash "$RELEASE" --target "$repo" --version 1.0.0 \
    --iac-units "$repo/units.json" --batch-commit --yes 2>/dev/null)
  echo "$out" | jq -e '.workspaces[] | select(.workspace == "modules/a") | .status == "released"'
  echo "$out" | jq -e '.workspaces[] | select(.workspace == "modules/b") | .status == "noop"'
  # a tagged at 1.0.0; b NOT.
  git -C "$repo" rev-parse --verify "refs/tags/modules/a/v1.0.0" >/dev/null 2>&1
  ! git -C "$repo" rev-parse --verify "refs/tags/modules/b/v1.0.0" >/dev/null 2>&1
}

@test "release.sh --iac-units: dry-run creates no tags" {
  repo=$(make_dag_repo)
  bash "$RELEASE" --target "$repo" --version 1.0.0 \
    --iac-units "$repo/units.json" --dry-run 2>/dev/null
  ! git -C "$repo" rev-parse --verify "refs/tags/app-1.0.0" >/dev/null 2>&1
  ! git -C "$repo" rev-parse --verify "refs/tags/modules/db/v1.0.0" >/dev/null 2>&1
}

# ────────────────────────────────────────────────────────────────────
# detect-workspace-changes.sh — accepts IaC units via --kind
# ────────────────────────────────────────────────────────────────────

@test "detect-workspace-changes: --kind accepts an IaC unit path; finds the change" {
  repo=$(make_iac_repo)
  root=$(git -C "$repo" rev-list --max-parents=0 HEAD | head -1)
  out=$(bash "$WS_DETECT" --target "$repo" --workspace modules/vpc --from "$root" --kind module 2>/dev/null)
  echo "$out" | jq -e 'length >= 1'
}

@test "detect-workspace-changes: rejects an unknown --kind" {
  repo=$(make_iac_repo)
  root=$(git -C "$repo" rev-list --max-parents=0 HEAD | head -1)
  run bash "$WS_DETECT" --target "$repo" --workspace modules/vpc --from "$root" --kind bogus
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "kind must be one of"
}

# ────────────────────────────────────────────────────────────────────
# Back-compat: code monorepo release is byte-for-byte unchanged
# ────────────────────────────────────────────────────────────────────

@test "release.sh code monorepo: unchanged — core@1.0.0 tag, no unit_kind in result" {
  repo=$(make_code_monorepo)
  out=$(bash "$RELEASE" --target "$repo" --workspace packages/core --version 1.0.0 \
    --strategy conventional-changelog --yes 2>/dev/null)
  echo "$out" | jq -e '.workspaces | length == 1'
  echo "$out" | jq -e '.workspaces[0].workspace == "packages/core"'
  echo "$out" | jq -e '.workspaces[0] | has("unit_kind") | not'
  git -C "$repo" rev-parse --verify "refs/tags/core@1.0.0" >/dev/null 2>&1
}

# ────────────────────────────────────────────────────────────────────
# Cluster-1 regression locks (BUG 1 / 2 / 3)
# ────────────────────────────────────────────────────────────────────

# BUG 1 — a CDK/Pulumi stack carries a FILE path (e.g. lib/db-stack.ts,
# Pulumi.prod.yaml). Such a unit is not independently path-releasable (no
# per-unit directory for a CHANGELOG, no version manifest, no depends_on), so it
# was silently dropped while release.sh still claimed status:"released" with
# workspaces:[] and exit 0 — a phantom success that tagged NOTHING. Lock that a
# file-path unit is NEVER a false success: it must be reported HONESTLY
# (a non-released status, the unit visible in workspaces[], non-zero exit) and
# tag nothing. (We chose to report file-path units honestly rather than invent a
# changelog location for them — see release.sh's BUG 1 comment.)
@test "release.sh --iac-units: CDK/Pulumi file-path unit is NOT a false success" {
  repo="$TMP/cdkfile-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$repo/lib"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@test"
  git -C "$repo" config user.name "test"
  echo '{"app":"npx ts-node bin/app.ts"}' > "$repo/cdk.json"
  echo 'export class DbStack {}' > "$repo/lib/db-stack.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "feat: scaffold cdk app"
  echo '// change' >> "$repo/lib/db-stack.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "fix(db): change db stack"
  # detect-stack emits CDK stacks with FILE paths; mirror that shape exactly.
  cat > "$repo/units.json" <<'JSON'
[
  {"kind":"stack","path":"lib/db-stack.ts","name":"db-stack","version":null}
]
JSON
  # Honest failure: zero of one requested unit released -> NOT plain success.
  run bash "$RELEASE" --target "$repo" --version 1.2.0 \
    --iac-units "$repo/units.json" --yes
  [ "$status" -ne 0 ]
  # Parse the JSON from a clean stdout-only capture (the run above also captures
  # the honest stderr warnings, which would break jq).
  out=$(bash "$RELEASE" --target "$repo" --version 1.2.0 \
    --iac-units "$repo/units.json" --yes 2>/dev/null) || true
  # The unit is visible (never silently dropped) and reported honestly.
  echo "$out" | jq -e '.status != "released"'
  echo "$out" | jq -e '.workspaces | length == 1'
  echo "$out" | jq -e '.workspaces[0].workspace == "lib/db-stack.ts"'
  echo "$out" | jq -e '.workspaces[0].status != "released"'
  # NOTHING was tagged — the core invariant.
  ! git -C "$repo" rev-parse --verify "refs/tags/lib/db-stack.ts/v1.2.0" >/dev/null 2>&1
  [ -z "$(git -C "$repo" tag -l)" ]
}

# BUG 2 — for kind=chart the tag prefix is `<name>-`, so the last-tag glob
# `app-*` ALSO matched sibling chart `app-worker`'s tags (app-worker-2.0.0).
# That wrong from-ref yielded zero app-scoped commits -> a silent noop, never
# tagging app. Lock that chart `app` releases off its OWN `app-1.0.0` baseline.
@test "release.sh --iac-units: chart releases off its own baseline, not a sibling chart's tag" {
  repo="$TMP/sibling-$BATS_TEST_NUMBER-$RANDOM"
  mkdir -p "$repo/charts/app" "$repo/charts/app-worker"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@test"
  git -C "$repo" config user.name "test"
  printf 'apiVersion: v2\nname: app\nversion: 1.0.0\n' > "$repo/charts/app/Chart.yaml"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "feat: scaffold app chart"
  git -C "$repo" tag "app-1.0.0"
  # app changes NOW (between app-1.0.0 and the later sibling tag).
  echo '# app change' >> "$repo/charts/app/Chart.yaml"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "fix: touch app chart"
  # Sibling chart app-worker is created and tagged LATER (higher version). The
  # buggy `app-*` glob would pick app-worker-2.0.0 as app's baseline.
  printf 'apiVersion: v2\nname: app-worker\nversion: 2.0.0\n' > "$repo/charts/app-worker/Chart.yaml"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "feat: add app-worker chart"
  git -C "$repo" tag "app-worker-2.0.0"
  cat > "$repo/units.json" <<'JSON'
[
  {"kind":"chart","path":"charts/app","name":"app","version":"1.0.0"}
]
JSON
  out=$(bash "$RELEASE" --target "$repo" --version 1.1.0 \
    --iac-units "$repo/units.json" --batch-commit --yes 2>/dev/null)
  app=$(echo "$out" | jq -c '.workspaces[] | select(.workspace == "charts/app")')
  # Baseline is app's OWN last tag, not the sibling's.
  echo "$app" | jq -e '.from == "app-1.0.0"'
  echo "$app" | jq -e '.status == "released"'
  echo "$app" | jq -e '.commits | length >= 1'
  echo "$app" | jq -e '.tag == "app-1.1.0"'
  # The real tag exists.
  git -C "$repo" rev-parse --verify "refs/tags/app-1.1.0" >/dev/null 2>&1
}

# BUG 3 — a chart/unit name containing a shell-glob metacharacter (* ? [) would
# produce an invalid tag pattern and false-matching --list globs. Lock that such
# a name fails CLEANLY (a guarded die), not via a mis-glob or git-option abort.
@test "release-workspace: a chart name with a glob metacharacter fails cleanly" {
  repo=$(make_iac_repo)
  run bash "$WS_RELEASE" --target "$repo" --workspace charts/app --version 0.4.0 \
    --kind chart --name 'app*'
  [ "$status" -ne 0 ]
  [ "$status" -ne 129 ]   # not a git "unknown option" abort
  echo "$output" | grep -F "shell-glob metacharacter"
}
