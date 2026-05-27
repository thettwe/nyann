#!/usr/bin/env bats
# test-load-profile-extends.bats — tests for the extends/composition feature.

setup() {
  export LOAD="${BATS_TEST_DIRNAME}/../../bin/load-profile.sh"
  export MERGE="${BATS_TEST_DIRNAME}/../../bin/merge-profiles.sh"
  export PLUGIN_ROOT="${BATS_TEST_DIRNAME}/../.."
  export TMP="${BATS_TEST_TMPDIR}"

  # Minimal user root with no existing profiles by default
  export USER_ROOT="$TMP/user-$$-$BATS_TEST_NUMBER"
  mkdir -p "$USER_ROOT/profiles"
}

# Helper: write a profile file
write_profile() {
  local dir="$1" name="$2" json="$3"
  mkdir -p "$dir"
  printf '%s\n' "$json" > "$dir/${name}.json"
}

# Grab the typescript-library starter as a known base
base_profile() {
  cat "$PLUGIN_ROOT/profiles/typescript-library.json"
}

# ────────────────────────────────────────────────────────────────────
# merge-profiles.sh unit tests
# ────────────────────────────────────────────────────────────────────

@test "merge: scalar override — overlay name wins" {
  write_profile "$TMP" base '{"name":"base","schemaVersion":1}'
  write_profile "$TMP" overlay '{"name":"child","schemaVersion":1}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e '.name == "child"'
}

@test "merge: object deep-merge — overlay key wins, base keys preserved" {
  write_profile "$TMP" base '{"name":"b","schemaVersion":1,"stack":{"primary_language":"go","framework":"gin"}}'
  write_profile "$TMP" overlay '{"name":"o","schemaVersion":1,"stack":{"framework":"echo"}}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e '.stack.primary_language == "go"'
  echo "$result" | jq -e '.stack.framework == "echo"'
}

@test "merge: array replace — overlay array stomps base entirely" {
  write_profile "$TMP" base '{"name":"b","schemaVersion":1,"branching":{"scopes":["a","b","c"]}}'
  write_profile "$TMP" overlay '{"name":"o","schemaVersion":1,"branching":{"scopes":["x"]}}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e '.branching.scopes == ["x"]'
}

@test "merge: absent in overlay — inherited from base" {
  write_profile "$TMP" base '{"name":"b","schemaVersion":1,"description":"from base"}'
  write_profile "$TMP" overlay '{"name":"o","schemaVersion":1}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e '.description == "from base"'
}

@test "merge: null in overlay — removes field from output" {
  write_profile "$TMP" base '{"name":"b","schemaVersion":1,"ci":{"enabled":true}}'
  write_profile "$TMP" overlay '{"name":"o","schemaVersion":1,"ci":null}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e 'has("ci") | not'
}

@test "merge: extends field is stripped from output" {
  write_profile "$TMP" base '{"name":"b","schemaVersion":1}'
  write_profile "$TMP" overlay '{"name":"o","schemaVersion":1,"extends":"b"}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e 'has("extends") | not'
}

@test "merge: _meta is stripped from both inputs" {
  write_profile "$TMP" base '{"name":"b","schemaVersion":1,"_meta":{"source":"starter"}}'
  write_profile "$TMP" overlay '{"name":"o","schemaVersion":1,"_meta":{"source":"user"}}'
  result=$(bash "$MERGE" --base "$TMP/base.json" --overlay "$TMP/overlay.json")
  echo "$result" | jq -e 'has("_meta") | not'
}

# ────────────────────────────────────────────────────────────────────
# load-profile.sh extends integration
# ────────────────────────────────────────────────────────────────────

@test "extends: child extends starter, merged output validates" {
  jq '.name = "child" | .extends = "typescript-library" | .branching.base_branches = ["develop"]' \
    "$PLUGIN_ROOT/profiles/typescript-library.json" > "$USER_ROOT/profiles/child.json"

  result=$(bash "$LOAD" child --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT" 2>/dev/null)
  echo "$result" | jq -e '.name == "child"'
  echo "$result" | jq -e '.branching.base_branches == ["develop"]'
  echo "$result" | jq -e '._meta.extends_resolved == true'
  echo "$result" | jq -e '._meta.extends_chain | length == 2'
  echo "$result" | jq -e '._meta.extends_chain[0] == "child"'
  echo "$result" | jq -e '._meta.extends_chain[1] == "typescript-library"'
}

@test "extends: non-extending profile has no extends_chain in _meta" {
  result=$(bash "$LOAD" typescript-library --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT" 2>/dev/null)
  echo "$result" | jq -e '._meta | has("extends_chain") | not'
  echo "$result" | jq -e '._meta | has("extends_resolved") | not'
}

@test "extends: depth-4 chain is refused" {
  # Chain: d → c → b → a → typescript-library = 4 extends hops (exceeds max 3)
  jq '.name="pf-a" | .extends="typescript-library"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/pf-a.json"
  jq '.name="pf-b" | .extends="pf-a"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/pf-b.json"
  jq '.name="pf-c" | .extends="pf-b"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/pf-c.json"
  jq '.name="pf-d" | .extends="pf-c"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/pf-d.json"

  run bash "$LOAD" pf-d --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "max depth"
}

@test "extends: circular chain is refused" {
  jq '.name="alpha" | .extends="beta"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/alpha.json"
  jq '.name="beta" | .extends="alpha"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/beta.json"

  run bash "$LOAD" alpha --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "circular"
}

@test "extends: missing parent dies with clear error" {
  jq '.name="orphan" | .extends="nonexistent"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/orphan.json"

  run bash "$LOAD" orphan --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F "not found"
}

@test "extends: 3-deep chain resolves correctly" {
  jq '.name="gp" | .description="from-gp"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/gp.json"
  jq '.name="mid" | .extends="gp" | .description="from-mid"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/mid.json"
  # leaf inherits description from mid (doesn't declare its own)
  jq 'del(.description) | .name="leaf" | .extends="mid"' "$PLUGIN_ROOT/profiles/typescript-library.json" \
    > "$USER_ROOT/profiles/leaf.json"

  result=$(bash "$LOAD" leaf --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT" 2>/dev/null)
  echo "$result" | jq -e '.name == "leaf"'
  echo "$result" | jq -e '.description == "from-mid"'
  echo "$result" | jq -e '._meta.extends_chain | length == 3'
}

@test "extends: merged output re-validates against profile schema" {
  local VALIDATE="${BATS_TEST_DIRNAME}/../../bin/validate-profile.sh"

  jq '.name="validchild" | .extends="typescript-library" | .branching.base_branches=["develop"]' \
    "$PLUGIN_ROOT/profiles/typescript-library.json" > "$USER_ROOT/profiles/validchild.json"

  result=$(bash "$LOAD" validchild --user-root "$USER_ROOT" --plugin-root "$PLUGIN_ROOT" 2>/dev/null)
  echo "$result" | jq 'del(._meta)' > "$TMP/validate-me.json"
  run bash "$VALIDATE" "$TMP/validate-me.json"
  [ "$status" -eq 0 ]
}
