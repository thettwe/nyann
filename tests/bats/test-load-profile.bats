#!/usr/bin/env bats
# bin/load-profile.sh — resolution + _meta surfacing.
# load-profile is the gateway every other profile-consuming script routes
# through; these tests cover the resolution order (user > team > starter)
# and the _meta shadow-detection contract directly.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LOAD="${REPO_ROOT}/bin/load-profile.sh"
  TMP=$(mktemp -d -t nyann-load.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  UR="$TMP/user-root"
  mkdir -p "$UR/profiles" "$UR/cache"
}

teardown() { rm -rf "$TMP"; }

# ---- baseline resolution ----------------------------------------------------

@test "loads a starter profile and emits _meta.source=starter" {
  out=$(bash "$LOAD" rust-cli --user-root "$UR" 2>/dev/null)
  src=$(echo "$out" | jq -r '._meta.source')
  [ "$src" = "starter" ]
  src_path=$(echo "$out" | jq -r '._meta.source_path')
  [ "$src_path" = "${REPO_ROOT}/profiles/rust-cli.json" ]
}

@test "loads a user profile and emits _meta.source=user" {
  cp "${REPO_ROOT}/profiles/python-cli.json" "$UR/profiles/python-cli.json"
  out=$(bash "$LOAD" python-cli --user-root "$UR" 2>/dev/null)
  [ "$(echo "$out" | jq -r '._meta.source')" = "user" ]
}

@test "exits 2 with a useful error when profile is not found" {
  run bash "$LOAD" totally-fake --user-root "$UR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -F -e "profile not found"
}

# ---- shadow surfacing -------------------------------------------------------

@test "_meta.shadowed_starter is populated when a user profile shadows a starter" {
  # Same name as a shipped starter → user version wins, but _meta records
  # the shadowed starter path so skill callers can warn the user.
  cp "${REPO_ROOT}/profiles/nextjs-prototype.json" "$UR/profiles/nextjs-prototype.json"
  out=$(bash "$LOAD" nextjs-prototype --user-root "$UR" 2>/dev/null)
  [ "$(echo "$out" | jq -r '._meta.source')" = "user" ]
  starter=$(echo "$out" | jq -r '._meta.shadowed_starter // ""')
  [ "$starter" = "${REPO_ROOT}/profiles/nextjs-prototype.json" ]
}

@test "_meta.shadowed_starter is absent when nothing is shadowed" {
  cp "${REPO_ROOT}/profiles/python-cli.json" "$UR/profiles/python-cli.json"
  # python-cli IS a shipped starter, so this user copy DOES shadow it —
  # bad fixture for this case. Rename the user copy to avoid collision.
  jq '.name = "my-personal-cli"' "$UR/profiles/python-cli.json" > "$UR/profiles/my-personal-cli.json"
  rm "$UR/profiles/python-cli.json"
  out=$(bash "$LOAD" my-personal-cli --user-root "$UR" 2>/dev/null)
  [ "$(echo "$out" | jq -r '._meta.source')" = "user" ]
  shadowed=$(echo "$out" | jq -r '._meta.shadowed_starter // ""')
  [ -z "$shadowed" ]
}

@test "stderr still logs the shadow notice (back-compat with stderr scrapers)" {
  cp "${REPO_ROOT}/profiles/rust-cli.json" "$UR/profiles/rust-cli.json"
  out=$(bash "$LOAD" rust-cli --user-root "$UR" 2>&1 >/dev/null)
  [[ "$out" == *"user profile shadows starter"* ]]
}

# ---- validation failure surfaces diagnostics + exit 4 (Bug A) ---------------

@test "invalid profile prints validation diagnostic and exits 4" {
  # Regression (Bug A): load-profile.sh sources _lib.sh which sets
  # `set -o errexit`. The old bare `validate-profile.sh ...` statement
  # made set -e abort BEFORE the diagnostics/exit-4 ran, so callers got a
  # bare non-zero code with no message. Guarding with `if !` restores the
  # documented behaviour: print validator output, exit 4.
  command -v uvx >/dev/null 2>&1 || command -v check-jsonschema >/dev/null 2>&1 \
    || skip "no schema validator available"
  # Start from a real starter, then break a required-typed field so it
  # parses as JSON but fails schema validation (forces the validator down
  # its failure path rather than jq's malformed-JSON path).
  jq '.branching.strategy = 12345' "${REPO_ROOT}/profiles/python-cli.json" \
    > "$UR/profiles/broken.json"
  run bash "$LOAD" broken --user-root "$UR"
  [ "$status" -eq 4 ]
  # The validator's diagnostic (not just a bare failure) must reach stderr.
  echo "$output" | grep -Fq "failed validation"
}

# ---- emitted JSON still passes schema validation ----------------------------

@test "loaded JSON (with _meta) re-validates against the profile schema" {
  command -v uvx >/dev/null 2>&1 || command -v check-jsonschema >/dev/null 2>&1 \
    || skip "no schema validator available"
  cp "${REPO_ROOT}/profiles/python-cli.json" "$UR/profiles/python-cli.json"
  bash "$LOAD" python-cli --user-root "$UR" > "$TMP/out.json" 2>/dev/null
  bash "${REPO_ROOT}/bin/validate-profile.sh" "$TMP/out.json" >/dev/null
}
