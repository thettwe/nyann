#!/usr/bin/env bats
# Fleet registry CRUD (bin/fleet.sh) — the local-repo list behind the fleet
# verbs. Covers add canonicalisation/idempotency/merging, remove by name and
# path, scan preview-vs-apply, prune, watch-list mirroring, and corruption
# resilience. No network: gh is absent from the stub PATH and the watch-list
# mirror goes through sentinel-aggregate.sh against a temp file.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-fleet.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  FLEET="$TMP/fleet.json"
  WL="$TMP/watch-list.json"
  SCRIPT="$REPO_ROOT/bin/fleet.sh"
}

teardown() { rm -rf "$TMP"; }

# make_repo <relpath> [origin-url] — seed a git repo under $TMP.
make_repo() {
  local p="$TMP/$1"
  mkdir -p "$p"
  ( cd "$p" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
  if [[ -n "${2-}" ]]; then
    git -C "$p" remote add origin "$2"
  fi
  printf '%s' "$p"
}

# --- add ---------------------------------------------------------------------

@test "--add registers a repo with basename as default name" {
  r=$(make_repo work/api)
  run bash "$SCRIPT" --add "$r" --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].path' "$FLEET")" = "$r" ]
  [ "$(jq -r '.[0].name' "$FLEET")" = "api" ]
}

@test "--add is idempotent (no duplicate on re-add)" {
  r=$(make_repo work/api)
  bash "$SCRIPT" --add "$r" --fleet-file "$FLEET"
  bash "$SCRIPT" --add "$r" --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
}

@test "--add canonicalises a subdir to the repo toplevel (deduped across depths)" {
  r=$(make_repo work/api)
  mkdir -p "$r/src/deep"
  bash "$SCRIPT" --add "$r" --fleet-file "$FLEET"
  bash "$SCRIPT" --add "$r/src/deep" --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
  [ "$(jq -r '.[0].path' "$FLEET")" = "$r" ]
}

@test "--add rejects a non-repo path and writes nothing" {
  mkdir -p "$TMP/notrepo"
  run bash "$SCRIPT" --add "$TMP/notrepo" --fleet-file "$FLEET"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not a git repo"
  [ ! -f "$FLEET" ]
}

@test "--add merges tags on re-add (deduped) and sets repo/profile" {
  r=$(make_repo work/api)
  bash "$SCRIPT" --add "$r" --tag backend --fleet-file "$FLEET"
  bash "$SCRIPT" --add "$r" --tag backend --tag prod --repo me/api --profile node-api --fleet-file "$FLEET"
  [ "$(jq -c '.[0].tags' "$FLEET")" = '["backend","prod"]' ]
  [ "$(jq -r '.[0].repo' "$FLEET")" = "me/api" ]
  [ "$(jq -r '.[0].profile' "$FLEET")" = "node-api" ]
}

@test "--add refuses a name that already names a different repo" {
  r1=$(make_repo work/api)
  r2=$(make_repo other/api)
  bash "$SCRIPT" --add "$r1" --fleet-file "$FLEET"
  run bash "$SCRIPT" --add "$r2" --fleet-file "$FLEET"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "distinct --name"
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
}

@test "--add with a distinct --name resolves the basename collision" {
  r1=$(make_repo work/api)
  r2=$(make_repo other/api)
  bash "$SCRIPT" --add "$r1" --fleet-file "$FLEET"
  bash "$SCRIPT" --add "$r2" --name api-other --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 2 ]
}

@test "--add rejects a malformed repo slug and an invalid profile" {
  r=$(make_repo work/api)
  run bash "$SCRIPT" --add "$r" --repo notaslug --fleet-file "$FLEET"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --add "$r" --profile "Bad_Name" --fleet-file "$FLEET"
  [ "$status" -ne 0 ]
}

# --- remove ------------------------------------------------------------------

@test "--remove by name removes exactly that entry" {
  r1=$(make_repo work/api)
  r2=$(make_repo work/web)
  bash "$SCRIPT" --add "$r1" --fleet-file "$FLEET"
  bash "$SCRIPT" --add "$r2" --fleet-file "$FLEET"
  bash "$SCRIPT" --remove api --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
  [ "$(jq -r '.[0].name' "$FLEET")" = "web" ]
}

@test "--remove by path removes the entry" {
  r=$(make_repo work/api)
  bash "$SCRIPT" --add "$r" --fleet-file "$FLEET"
  bash "$SCRIPT" --remove "$r" --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 0 ]
}

@test "--remove of an absent name is a no-op" {
  r=$(make_repo work/api)
  bash "$SCRIPT" --add "$r" --fleet-file "$FLEET"
  run bash "$SCRIPT" --remove ghost --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
}

@test "--remove refuses an ambiguous name (hand-edited duplicate)" {
  r1=$(make_repo work/api)
  r2=$(make_repo other/api2)
  jq -n --arg p1 "$r1" --arg p2 "$r2" \
    '[{path:$p1, name:"api"}, {path:$p2, name:"api"}]' > "$FLEET"
  run bash "$SCRIPT" --remove api --fleet-file "$FLEET"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "remove by path"
  [ "$(jq 'length' "$FLEET")" -eq 2 ]
}

# --- list --------------------------------------------------------------------

@test "--list prints [] when no registry exists" {
  run bash "$SCRIPT" --list --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 0 ]
}

@test "corrupt registry (non-array) is treated as empty with a warning" {
  echo '{"oops": true}' > "$FLEET"
  run bash "$SCRIPT" --list --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "not a JSON array"
  [ "$(echo "$output" | grep -v nyann | jq 'length')" -eq 0 ]
}

# --- scan --------------------------------------------------------------------

@test "--scan previews unregistered repos without writing" {
  make_repo scanroot/a >/dev/null
  make_repo scanroot/nested/b >/dev/null
  run bash "$SCRIPT" --scan "$TMP/scanroot" --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Preview only"
  [ ! -f "$FLEET" ]
}

@test "--scan --apply registers discovered repos and skips already-registered ones" {
  a=$(make_repo scanroot/a)
  make_repo scanroot/nested/b >/dev/null
  bash "$SCRIPT" --add "$a" --fleet-file "$FLEET"
  bash "$SCRIPT" --scan "$TMP/scanroot" --apply --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 2 ]
  [ "$(jq -r '[.[].name] | sort | join(",")' "$FLEET")" = "a,b" ]
}

@test "--scan respects --depth (deep repo not found at depth 1)" {
  make_repo scanroot/nested/deep/c >/dev/null
  run bash "$SCRIPT" --scan "$TMP/scanroot" --depth 1 --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "deep/c"
}

@test "--scan --apply fans tags out across the batch but not --name" {
  make_repo scanroot/a >/dev/null
  make_repo scanroot/b >/dev/null
  bash "$SCRIPT" --scan "$TMP/scanroot" --apply --tag work --fleet-file "$FLEET"
  [ "$(jq '[.[] | select(.tags == ["work"])] | length' "$FLEET")" -eq 2 ]
  [ "$(jq -r '[.[].name] | sort | join(",")' "$FLEET")" = "a,b" ]
}

# --- prune -------------------------------------------------------------------

@test "--prune previews dead entries without writing; --apply drops only them" {
  r1=$(make_repo work/alive)
  r2=$(make_repo work/dead)
  bash "$SCRIPT" --add "$r1" --fleet-file "$FLEET"
  bash "$SCRIPT" --add "$r2" --fleet-file "$FLEET"
  rm -rf "$r2"
  run bash "$SCRIPT" --prune --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Preview only"
  [ "$(jq 'length' "$FLEET")" -eq 2 ]
  bash "$SCRIPT" --prune --apply --fleet-file "$FLEET"
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
  [ "$(jq -r '.[0].name' "$FLEET")" = "alive" ]
}

# --- watch-list mirroring ----------------------------------------------------

@test "--add --watch with --repo mirrors the slug into the watch-list" {
  r=$(make_repo work/api)
  bash "$SCRIPT" --add "$r" --repo me/api --watch \
    --fleet-file "$FLEET" --watch-list "$WL"
  [ "$(jq -r '.[0].repo' "$WL")" = "me/api" ]
  [ "$(jq -r '.[0].repo' "$FLEET")" = "me/api" ]
}

@test "--add --watch resolves the slug from the origin remote" {
  r=$(make_repo work/api "git@github.com:me/api.git")
  bash "$SCRIPT" --add "$r" --watch --fleet-file "$FLEET" --watch-list "$WL"
  [ "$(jq -r '.[0].repo' "$WL")" = "me/api" ]
  [ "$(jq -r '.[0].repo' "$FLEET")" = "me/api" ]
}

@test "--add --watch without a resolvable slug warns but keeps the fleet entry" {
  r=$(make_repo work/api)
  run bash "$SCRIPT" --add "$r" --watch --fleet-file "$FLEET" --watch-list "$WL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "skipped watch-list mirror"
  [ "$(jq 'length' "$FLEET")" -eq 1 ]
  [ ! -f "$WL" ]
}

# --- suggest-org -------------------------------------------------------------

@test "--suggest-org soft-skips to [] when gh is unavailable" {
  stub="$TMP/stubpath"
  mkdir -p "$stub"
  # Minimal PATH that has bash/jq/git but NO gh.
  for t in bash jq git dirname basename mktemp mkdir cat sed grep sort find head tr cut date hostname mv rm ps sleep uname; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -s "$p" "$stub/$t"
  done
  run env PATH="$stub" bash "$SCRIPT" --suggest-org myorg --fleet-file "$FLEET"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "gh unavailable"
  [ "$(echo "$output" | grep -v nyann | jq 'length')" -eq 0 ]
}

# --- schema shape ------------------------------------------------------------

@test "registry written by --add validates against fleet-registry schema shape" {
  r=$(make_repo work/api)
  bash "$SCRIPT" --add "$r" --repo me/api --profile node-api --tag t1 --fleet-file "$FLEET"
  # Structural assertions mirroring schemas/fleet-registry.schema.json
  # (full check-jsonschema validation lives in test-schema-validation.bats).
  [ "$(jq -r 'type' "$FLEET")" = "array" ]
  [ "$(jq -r '.[0] | has("path")' "$FLEET")" = "true" ]
  [ "$(jq -r '.[0].path | startswith("/")' "$FLEET")" = "true" ]
  [ "$(jq -r '.[0] | keys - ["name","path","profile","repo","tags"] | length' "$FLEET")" = "0" ]
}
