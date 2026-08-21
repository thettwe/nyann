#!/usr/bin/env bats
# Bulk fleet audit (bin/fleet-doctor.sh) — registry iteration, per-repo
# profile resolution, failure isolation, worst-of exit codes, cached mode,
# the drift roll-up, and the FleetReport shape. The per-repo doctor is
# replaced with a stub (--doctor seam, mirroring sentinel-aggregate's
# --sentinel) so no real audit machinery runs; one integration test at the
# end exercises the real doctor.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-fdoc.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  FLEET="$TMP/fleet.json"
  FD="$REPO_ROOT/bin/fleet-doctor.sh"
  FLEET_SH="$REPO_ROOT/bin/fleet.sh"
  STUB_LOG="$TMP/stub.log"
  export STUB_LOG

  # Stub doctor: behavior driven by marker files in each target repo
  # (.stub-score, .stub-missing, .stub-fail); logs every invocation.
  STUB="$TMP/stub-doctor.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
target=""; profile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)  target="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --persist) echo "persist $target" >> "$STUB_LOG"; shift ;;
    --gh)      echo "gh $2" >> "$STUB_LOG"; shift 2 ;;
    *) shift ;;
  esac
done
echo "run target=$target profile=$profile" >> "$STUB_LOG"
[[ -f "$target/.stub-fail" ]] && exit 7
score=$(cat "$target/.stub-score" 2>/dev/null || echo 90)
missing=$(cat "$target/.stub-missing" 2>/dev/null || echo 0)
jq -n --argjson s "$score" --argjson m "$missing" '{
  summary: {missing:$m, misconfigured:0, non_compliant_commits:0,
            broken_links:0, orphans:0, stale_docs:0, misplaced:0,
            subsystem_errors:0, claude_md_status:"ok"},
  missing: (if $m > 0 then [range($m) | {path: "file-\(.)", detail: "stubbed"}] else [] end),
  misconfigured: [],
  health_score: {score:$s, breakdown: (if $m > 0 then {missing:-10} else {} end)}
}'
EOF
  chmod +x "$STUB"
}

teardown() { rm -rf "$TMP"; }

# make_repo <relpath> [score] [missing] — git repo with stub markers, registered.
make_repo() {
  local p="$TMP/$1"
  mkdir -p "$p"
  ( cd "$p" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
  [[ -n "${2-}" ]] && echo "$2" > "$p/.stub-score"
  [[ -n "${3-}" ]] && echo "$3" > "$p/.stub-missing"
  bash "$FLEET_SH" --add "$p" --fleet-file "$FLEET" 2>/dev/null
  printf '%s' "$p"
}

fdoc() { bash "$FD" --fleet-file "$FLEET" --doctor "$STUB" "$@"; }

# seed_health <path> <score> <iso-ts> — persisted health history for cached mode.
seed_health() {
  mkdir -p "$1/memory"
  jq -n --argjson s "$2" --arg ts "$3" \
    '{scores: [{timestamp:$ts, score:$s, profile:"default", breakdown:{}}],
      trend: {direction:"stable", delta:0, window_days:7}}' > "$1/memory/health.json"
}

# --- basics ------------------------------------------------------------------

@test "empty registry → exit 0, count 0, empty-fleet hint" {
  run fdoc
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "registry is empty"
}

@test "repos are sorted worst-first in the report" {
  make_repo good 95 0 >/dev/null
  make_repo bad 40 2 >/dev/null
  make_repo mid 70 1 >/dev/null
  run fdoc --json
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '[.repos[].name] | join(",")')" = "bad,mid,good" ]
}

@test "summary aggregates: avg/min/max/below_threshold/critical" {
  make_repo a 95 0 >/dev/null
  make_repo b 45 3 >/dev/null
  run fdoc --json --threshold 70
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.summary.avg')" = "70" ]
  [ "$(echo "$report" | jq -r '.summary.min')" = "45" ]
  [ "$(echo "$report" | jq -r '.summary.max')" = "95" ]
  [ "$(echo "$report" | jq -r '.summary.below_threshold')" = "1" ]
  [ "$(echo "$report" | jq -r '.summary.critical_repos')" = "1" ]
}

@test "worst-of exit code: clean fleet 0, any critical 5" {
  make_repo a 95 0 >/dev/null
  run fdoc --json
  [ "$status" -eq 0 ]
  make_repo b 45 3 >/dev/null
  run fdoc --json
  [ "$status" -eq 5 ]
}

@test "severity derives from the report JSON (drifted repo counts critical even though the stub exits 0)" {
  make_repo bad 40 2 >/dev/null
  run fdoc --json
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].exit_code')" = "5" ]
  [ "$(echo "$report" | jq -r '.repos[0].drift.missing')" = "2" ]
}

# --- profile resolution ------------------------------------------------------

@test "fleet-entry profile pin wins and is passed to doctor" {
  p=$(make_repo pinned 90 0)
  bash "$FLEET_SH" --add "$p" --profile node-api --fleet-file "$FLEET"
  run fdoc --json
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].profile')" = "node-api" ]
  [ "$(echo "$report" | jq -r '.repos[0].profile_source')" = "pin" ]
  grep -q "profile=node-api" "$STUB_LOG"
}

@test ".nyann/profile hint is used when no pin exists" {
  p=$(make_repo hinted 90 0)
  mkdir -p "$p/.nyann"
  echo "python-cli" > "$p/.nyann/profile"
  run fdoc --json
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].profile')" = "python-cli" ]
  [ "$(echo "$report" | jq -r '.repos[0].profile_source')" = "repo" ]
}

@test "CLAUDE.md profile declaration is used when no pin or hint file exists" {
  p=$(make_repo declared 90 0)
  printf 'Setup notes.\n\nProfile: `go-service`\n' > "$p/CLAUDE.md"
  run fdoc --json
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].profile')" = "go-service" ]
  [ "$(echo "$report" | jq -r '.repos[0].profile_source')" = "repo" ]
}

@test "nothing resolvable falls back to default with profile_source=fallback" {
  make_repo bare 90 0 >/dev/null
  run fdoc --json
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].profile')" = "default" ]
  [ "$(echo "$report" | jq -r '.repos[0].profile_source')" = "fallback" ]
}

# --- filters -----------------------------------------------------------------

@test "--tag filters to matching entries" {
  a=$(make_repo a 90 0)
  make_repo b 90 0 >/dev/null
  bash "$FLEET_SH" --add "$a" --tag backend --fleet-file "$FLEET"
  run fdoc --json --tag backend
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos | length')" = "1" ]
  [ "$(echo "$report" | jq -r '.repos[0].name')" = "a" ]
}

@test "--only filters by name CSV" {
  make_repo a 90 0 >/dev/null
  make_repo b 90 0 >/dev/null
  make_repo c 90 0 >/dev/null
  run fdoc --json --only a,c
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '[.repos[].name] | sort | join(",")')" = "a,c" ]
}

# --- failure isolation -------------------------------------------------------

@test "a failing repo becomes status=error and the run continues (exit 4)" {
  p=$(make_repo broken 90 0)
  touch "$p/.stub-fail"
  make_repo fine 95 0 >/dev/null
  run fdoc --json
  [ "$status" -eq 4 ]
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[] | select(.name=="broken") | .status')" = "error" ]
  [ "$(echo "$report" | jq -r '.repos[] | select(.name=="fine") | .status')" = "ok" ]
}

@test "a dead registry path becomes status=error, not fatal" {
  p=$(make_repo doomed 90 0)
  make_repo fine 95 0 >/dev/null
  rm -rf "$p"
  run fdoc --json
  [ "$status" -eq 4 ]
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[] | select(.name=="doomed") | .status')" = "error" ]
  echo "$report" | jq -r '.repos[] | select(.name=="doomed") | .error' | grep -q "not a git repo"
}

# --- parallelism -------------------------------------------------------------

@test "--jobs 2 produces the same rows as sequential" {
  make_repo a 95 0 >/dev/null
  make_repo b 45 2 >/dev/null
  make_repo c 70 1 >/dev/null
  seq_out=$(fdoc --json 2>/dev/null | jq -S '[.repos[] | {name, score, status, exit_code}]')
  par_out=$(fdoc --json --jobs 2 2>/dev/null | jq -S '[.repos[] | {name, score, status, exit_code}]')
  [ "$seq_out" = "$par_out" ]
}

@test "--jobs above 8 is rejected" {
  run fdoc --jobs 9
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "between 1 and 8"
}

# --- persist -----------------------------------------------------------------

@test "--persist forwards to each repo's doctor" {
  make_repo a 90 0 >/dev/null
  make_repo b 90 0 >/dev/null
  fdoc --json --persist >/dev/null 2>&1
  [ "$(grep -c '^persist ' "$STUB_LOG")" -eq 2 ]
}

# --- cached mode -------------------------------------------------------------

@test "--cached reads persisted history and never invokes doctor" {
  p=$(make_repo a 90 0)
  seed_health "$p" 82 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run fdoc --json --cached
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.mode')" = "cached" ]
  [ "$(echo "$report" | jq -r '.repos[0].score')" = "82" ]
  [ "$(echo "$report" | jq -r '.repos[0].status')" = "ok" ]
  [ ! -f "$STUB_LOG" ] || ! grep -q '^run ' "$STUB_LOG"
}

@test "--cached flags an entry older than --stale-days as stale" {
  p=$(make_repo a 90 0)
  seed_health "$p" 82 "2026-01-01T00:00:00Z"
  run fdoc --json --cached --stale-days 7
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].status')" = "stale" ]
  [ "$status" -eq 4 ]
}

@test "--cached with no history is status=missing" {
  make_repo a 90 0 >/dev/null
  run fdoc --json --cached
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].status')" = "missing" ]
  [ "$(echo "$report" | jq -r '.repos[0].score')" = "null" ]
}

@test "--drift with --cached is refused" {
  run fdoc --cached --drift
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "live run"
}

@test "--persist with --cached is refused" {
  run fdoc --cached --persist
  [ "$status" -ne 0 ]
}

# --- drift roll-up -----------------------------------------------------------

@test "--drift embeds drift_report only for drifted repos and renders repo-tagged findings" {
  make_repo clean 95 0 >/dev/null
  make_repo dirty 50 2 >/dev/null
  run fdoc --drift
  echo "$output" | grep -q "DRIFT FINDINGS (1 repos)"
  echo "$output" | grep -q "── dirty ("
  echo "$output" | grep -q "✗ missing: file-0"
  ! echo "$output" | grep -q "── clean ("
  json=$(fdoc --json --drift 2>/dev/null) || true
  [ "$(echo "$json" | jq -r '.repos[] | select(.name=="dirty") | .drift_report.summary.missing')" = "2" ]
  [ "$(echo "$json" | jq -r '.repos[] | select(.name=="clean") | has("drift_report")')" = "false" ]
}

# --- markdown ----------------------------------------------------------------

@test "--markdown emits a table with header row and fallback marker" {
  make_repo a 90 0 >/dev/null
  run fdoc --markdown
  echo "$output" | grep -q '^| Repo | Score |'
  echo "$output" | grep -q 'default (?)'
}

@test "--markdown and --json are mutually exclusive" {
  run fdoc --markdown --json
  [ "$status" -ne 0 ]
}

# --- schema shape ------------------------------------------------------------

@test "FleetReport keys match the schema surface" {
  make_repo a 90 1 >/dev/null
  json=$(fdoc --json --drift 2>/dev/null) || true
  [ "$(echo "$json" | jq -r 'keys - ["generated_at","mode","repos","summary"] | length')" = "0" ]
  [ "$(echo "$json" | jq -r '.repos[0] | keys - ["delta","direction","drift","drift_report","error","exit_code","health_age_days","name","path","profile","profile_source","score","sparkline","status","worst_category"] | length')" = "0" ]
  [ "$(echo "$json" | jq -r '.summary | keys - ["avg","below_threshold","count","critical_repos","max","min","threshold"] | length')" = "0" ]
}

# --- integration: the real doctor --------------------------------------------

@test "integration: real doctor over a seeded repo produces a scored row" {
  p="$TMP/real"
  mkdir -p "$p"
  ( cd "$p" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
  bash "$FLEET_SH" --add "$p" --fleet-file "$FLEET" 2>/dev/null
  run bash "$FD" --fleet-file "$FLEET" --json --timeout 120
  report=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$report" | jq -r '.repos[0].score | type')" = "number" ]
  [ "$(echo "$report" | jq -r '.repos[0].profile')" = "default" ]
}
