#!/usr/bin/env bats
# Bulk fleet remediation planning + bookkeeping (bin/fleet-retrofit.sh).
# The script layer never mutates a repo — these tests cover the read-only
# classification (--plan), the outcome bookkeeping (--record/--finalize),
# and the FleetRunResult contract. The per-repo drift computation is a stub
# retrofit (--retrofit seam, mirroring fleet-doctor's --doctor).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-fretro.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  FLEET="$TMP/fleet.json"
  RUN="$TMP/run.json"
  FR="$REPO_ROOT/bin/fleet-retrofit.sh"
  FLEET_SH="$REPO_ROOT/bin/fleet.sh"

  # Stub retrofit: drift driven by marker files in each target repo.
  STUB="$TMP/stub-retrofit.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --profile) shift 2 ;;
    *) shift ;;
  esac
done
missing=$(cat "$target/.stub-drift" 2>/dev/null || echo 0)
cm=$(cat "$target/.stub-cmstatus" 2>/dev/null || echo ok)
jq -n --argjson m "$missing" --arg cm "$cm" '{
  summary: {missing:$m, misconfigured:0, non_compliant_commits:0,
            broken_links:0, orphans:0, stale_docs:0, misplaced:0,
            subsystem_errors:0, claude_md_status:$cm}}'
EOF
  chmod +x "$STUB"
}

teardown() { rm -rf "$TMP"; }

# make_repo <relpath> — git repo registered in the fleet.
make_repo() {
  local p="$TMP/$1"
  mkdir -p "$p"
  ( cd "$p" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
  bash "$FLEET_SH" --add "$p" --fleet-file "$FLEET" 2>/dev/null
  printf '%s' "$p"
}

# govern <path> — give the repo a boot record so it classifies as governed.
govern() {
  mkdir -p "$1/memory/.nyann/bootstraps/2026-01-01T000000"
  echo '{}' > "$1/memory/.nyann/bootstraps/2026-01-01T000000/manifest.json"
}

fplan() { bash "$FR" --plan --fleet-file "$FLEET" --retrofit "$STUB" "$@"; }

# --- plan: classification ----------------------------------------------------

@test "empty registry plans to count 0, exit 0" {
  run fplan
  [ "$status" -eq 0 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.summary.count')" = "0" ]
  [ "$(echo "$plan" | jq -r '.phase')" = "plan" ]
}

@test "clean governed repo → classification clean, action clean, exit 0" {
  p=$(make_repo clean)
  govern "$p"
  run fplan
  [ "$status" -eq 0 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[0].classification')" = "clean" ]
  [ "$(echo "$plan" | jq -r '.repos[0].action')" = "clean" ]
  [ "$(echo "$plan" | jq -r '.repos[0].suggested_action')" = "none" ]
}

@test "drifted governed repo → retrofit suggested, pending, exit 4" {
  p=$(make_repo dirty)
  govern "$p"
  echo 3 > "$p/.stub-drift"
  run fplan
  [ "$status" -eq 4 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[0].classification')" = "drifted" ]
  [ "$(echo "$plan" | jq -r '.repos[0].suggested_action')" = "retrofit" ]
  [ "$(echo "$plan" | jq -r '.repos[0].action')" = "pending" ]
  [ "$(echo "$plan" | jq -r '.repos[0].drift.missing')" = "3" ]
}

@test "claude_md_status alone (absent) marks a governed repo drifted" {
  p=$(make_repo cmonly)
  govern "$p"
  echo absent > "$p/.stub-cmstatus"
  run fplan
  [ "$status" -eq 4 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[0].classification')" = "drifted" ]
}

@test "ungoverned repo without --bootstrap-missing is skipped with a CTA" {
  make_repo bare >/dev/null
  run fplan
  [ "$status" -eq 0 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[0].classification')" = "ungoverned" ]
  [ "$(echo "$plan" | jq -r '.repos[0].action')" = "skipped" ]
  echo "$plan" | jq -r '.repos[0].detail' | grep -q "bootstrap-missing"
}

@test "--bootstrap-missing plans ungoverned repos for bootstrap (pending, exit 4)" {
  make_repo bare >/dev/null
  run fplan --bootstrap-missing
  [ "$status" -eq 4 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[0].suggested_action')" = "bootstrap" ]
  [ "$(echo "$plan" | jq -r '.repos[0].action')" = "pending" ]
  [ "$(echo "$plan" | jq -r '.bootstrap_missing')" = "true" ]
}

@test "a profile hint makes a repo governed even without a boot record" {
  p=$(make_repo hinted)
  mkdir -p "$p/.nyann"
  echo "python-cli" > "$p/.nyann/profile"
  run fplan
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[0].classification')" = "clean" ]
  [ "$(echo "$plan" | jq -r '.repos[0].profile')" = "python-cli" ]
  [ "$(echo "$plan" | jq -r '.repos[0].profile_source')" = "repo" ]
}

@test "a dead registry path is an error row, run continues, exit 4" {
  p=$(make_repo doomed)
  q=$(make_repo fine)
  govern "$q"
  rm -rf "$p"
  run fplan
  [ "$status" -eq 4 ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos[] | select(.name=="doomed") | .classification')" = "error" ]
  [ "$(echo "$plan" | jq -r '.repos[] | select(.name=="doomed") | .action')" = "failed" ]
  [ "$(echo "$plan" | jq -r '.repos[] | select(.name=="fine") | .classification')" = "clean" ]
}

@test "plan sorts error → drifted → ungoverned → clean" {
  c=$(make_repo cclean); govern "$c"
  d=$(make_repo bdirty); govern "$d"; echo 2 > "$d/.stub-drift"
  make_repo dbare >/dev/null
  e=$(make_repo aerror); rm -rf "$e"
  run fplan
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '[.repos[].classification] | join(",")')" = "error,drifted,ungoverned,clean" ]
}

@test "--only filters the plan to named repos" {
  a=$(make_repo a); govern "$a"
  b=$(make_repo b); govern "$b"
  run fplan --only b
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -r '.repos | length')" = "1" ]
  [ "$(echo "$plan" | jq -r '.repos[0].name')" = "b" ]
}

@test "--plan --run-file writes the same plan it prints" {
  p=$(make_repo a); govern "$p"
  run fplan --run-file "$RUN"
  [ -f "$RUN" ]
  plan=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$plan" | jq -S .)" = "$(jq -S . "$RUN")" ]
}

# --- record ------------------------------------------------------------------

@test "--record updates the repo row and bumps phase to in-progress" {
  p=$(make_repo dirty); govern "$p"; echo 2 > "$p/.stub-drift"
  fplan --run-file "$RUN" >/dev/null 2>&1 || true
  run bash "$FR" --record --run-file "$RUN" --repo "$p" --action retrofitted --exit-code 0 --detail "applied 4 writes"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.phase' "$RUN")" = "in-progress" ]
  [ "$(jq -r '.repos[0].action' "$RUN")" = "retrofitted" ]
  [ "$(jq -r '.repos[0].exit_code' "$RUN")" = "0" ]
  [ "$(jq -r '.repos[0].detail' "$RUN")" = "applied 4 writes" ]
}

@test "--record rejects an unknown repo path and an invalid action" {
  p=$(make_repo a); govern "$p"
  fplan --run-file "$RUN" >/dev/null 2>&1 || true
  run bash "$FR" --record --run-file "$RUN" --repo /nope --action retrofitted
  [ "$status" -ne 0 ]
  run bash "$FR" --record --run-file "$RUN" --repo "$p" --action exploded
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "action must be one of"
}

@test "--record without a run file dies clearly" {
  run bash "$FR" --record --run-file "$RUN" --repo /x --action skipped
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "run file not found"
}

# --- finalize ----------------------------------------------------------------

@test "--finalize converts pending to skipped and fills the summary" {
  a=$(make_repo adirty); govern "$a"; echo 1 > "$a/.stub-drift"
  b=$(make_repo bdirty); govern "$b"; echo 1 > "$b/.stub-drift"
  c=$(make_repo cclean); govern "$c"
  fplan --run-file "$RUN" >/dev/null 2>&1 || true
  bash "$FR" --record --run-file "$RUN" --repo "$a" --action retrofitted --exit-code 0
  run bash "$FR" --finalize --run-file "$RUN"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.phase' "$RUN")" = "final" ]
  [ "$(jq -r --arg p "$b" '.repos[] | select(.path == $p) | .action' "$RUN")" = "skipped" ]
  [ "$(jq -r '.summary.retrofitted' "$RUN")" = "1" ]
  [ "$(jq -r '.summary.skipped' "$RUN")" = "1" ]
  [ "$(jq -r '.summary.clean' "$RUN")" = "1" ]
  jq -r '.repos[] | select(.action=="skipped") | .detail' "$RUN" | grep -q "before this repo"
}

@test "full lifecycle: plan → record (retrofitted + declined) → finalize" {
  a=$(make_repo a); govern "$a"; echo 1 > "$a/.stub-drift"
  b=$(make_repo b); govern "$b"; echo 1 > "$b/.stub-drift"
  fplan --run-file "$RUN" >/dev/null 2>&1 || true
  bash "$FR" --record --run-file "$RUN" --repo "$a" --action retrofitted --exit-code 0
  bash "$FR" --record --run-file "$RUN" --repo "$b" --action declined
  bash "$FR" --finalize --run-file "$RUN" >/dev/null
  [ "$(jq -r '.summary.retrofitted' "$RUN")" = "1" ]
  [ "$(jq -r '.summary.declined' "$RUN")" = "1" ]
  [ "$(jq -r '.summary.drifted' "$RUN")" = "2" ]
}

# --- schema shape ------------------------------------------------------------

@test "FleetRunResult keys match the schema surface" {
  p=$(make_repo a); govern "$p"; echo 1 > "$p/.stub-drift"
  make_repo bare >/dev/null
  plan=$(fplan --run-file "$RUN" 2>/dev/null) || true
  [ "$(echo "$plan" | jq -r 'keys - ["bootstrap_missing","generated_at","phase","repos","summary"] | length')" = "0" ]
  [ "$(echo "$plan" | jq -r '.repos[0] | keys - ["action","classification","detail","drift","exit_code","name","path","profile","profile_source","suggested_action"] | length')" = "0" ]
  [ "$(echo "$plan" | jq -r '.summary | keys - ["bootstrapped","clean","count","declined","drifted","errors","failed","retrofitted","skipped","ungoverned"] | length')" = "0" ]
}
