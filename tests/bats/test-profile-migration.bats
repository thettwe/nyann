#!/usr/bin/env bats
# bin/migrate-profile.sh + load-profile auto-migrate.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MIGRATE="${REPO_ROOT}/bin/migrate-profile.sh"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "v1 profile → stdout keeps schemaVersion=1 (no-op at CURRENT=1)" {
  cp "${REPO_ROOT}/profiles/default.json" "$TMP/p.json"
  run bash "$MIGRATE" "$TMP/p.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.schemaVersion')" = "1" ]
}

@test "--in-place rewrites file but keeps v1" {
  cp "${REPO_ROOT}/profiles/default.json" "$TMP/p.json"
  run bash "$MIGRATE" --in-place "$TMP/p.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schemaVersion' "$TMP/p.json")" = "1" ]
}

@test "schemaVersion > CURRENT → hard error" {
  jq '.schemaVersion = 99' "${REPO_ROOT}/profiles/default.json" > "$TMP/p.json"
  run bash "$MIGRATE" "$TMP/p.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq 'newer than this nyann supports'
}

@test "non-numeric schemaVersion → hard error" {
  python3 -c "import json; d=json.load(open('${REPO_ROOT}/profiles/default.json')); d['schemaVersion']='abc'; json.dump(d, open('$TMP/p.json','w'))"
  run bash "$MIGRATE" "$TMP/p.json"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq 'unknown schemaVersion'
}
