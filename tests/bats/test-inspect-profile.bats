#!/usr/bin/env bats
# bin/inspect-profile.sh — human-readable profile summary.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSPECT="${REPO_ROOT}/bin/inspect-profile.sh"
  TMP=$(mktemp -d)
  UR="$TMP/user-root"
  mkdir -p "$UR/profiles"
}

teardown() { rm -rf "$TMP"; }

@test "missing profile name dies" {
  run bash "$INSPECT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "usage"
}

@test "nextjs-prototype starter renders expected sections" {
  run bash "$INSPECT" nextjs-prototype --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "Profile: nextjs-prototype"
  echo "$output" | grep -F -e "Stack:"
  echo "$output" | grep -F -e "Branching:"
  echo "$output" | grep -F -e "Hooks:"
  echo "$output" | grep -F -e "Extras:"
  echo "$output" | grep -F -e "Documentation:"
}

@test "python-cli starter renders ruff blurbs" {
  run bash "$INSPECT" python-cli --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "ruff"
  echo "$output" | grep -F -e "Python"
}

@test "go-service (new starter) renders golangci-lint blurb" {
  run bash "$INSPECT" go-service --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "golangci-lint"
}

@test "rust-cli (new starter) renders clippy blurb" {
  run bash "$INSPECT" rust-cli --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "clippy"
}

@test "unknown profile exits 2" {
  run bash "$INSPECT" totally-fake --user-root "$UR"
  [ "$status" -eq 2 ]
}

@test "user profile shadows starter with same name" {
  # Seed a user profile named nextjs-prototype with a distinctive description.
  jq '.description = "SHADOWED by user"' "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$UR/profiles/nextjs-prototype.json"
  run bash "$INSPECT" nextjs-prototype --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "SHADOWED by user"
}

@test "shadow banner appears prominently in inspect output" {
  # Surface check: a user profile that shadows a starter must produce a
  # visible "shadows a built-in starter" banner so users notice the
  # silent override. The loader also writes a stderr log line, but
  # stderr is easy to lose; this banner sits at the top of the
  # rendered output where it's hard to miss.
  jq '.' "${REPO_ROOT}/profiles/python-cli.json" > "$UR/profiles/python-cli.json"
  run bash "$INSPECT" python-cli --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "shadows a built-in starter"
  echo "$output" | grep -F -e "${REPO_ROOT}/profiles/python-cli.json"
}

@test "no shadow banner when loading an unshadowed starter" {
  # Negative case: a vanilla starter with no user override produces no
  # banner. Catches a regression where the banner fires on every load.
  run bash "$INSPECT" rust-cli --user-root "$UR"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -F -e "shadows a built-in starter"
  ! echo "$output" | grep -F -e "shadows"
}

@test "invalid name flag rejected cleanly" {
  run bash "$INSPECT" --bogus-flag
  [ "$status" -ne 0 ]
}

@test "go-service renders gofmt blurb (not 'custom hook')" {
  # Regression: profile shipped "go-fmt" but hook_blurb() mapped "gofmt".
  # A mismatched id would render as "custom hook".
  run bash "$INSPECT" go-service --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "gofmt on staged Go files"
  ! echo "$output" | grep -F -e "go-fmt"
}

@test "rust-cli renders rustfmt blurb (not 'custom hook')" {
  # Regression: profile shipped "rustfmt" but hook_blurb() mapped "fmt".
  run bash "$INSPECT" rust-cli --user-root "$UR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "rustfmt on staged Rust files"
  # No "custom hook" fallback for any pre_commit id we ship.
  ! echo "$output" | grep -F -e "custom hook"
}

@test "every bundled profile hook id has a mapped blurb" {
  # Drift guard: if any bundled profile adds a pre_commit id with no
  # matching case in hook_blurb(), inspect-profile will render "custom
  # hook" for it. Fail the build so the profile + code get updated
  # together.
  for pf in "${REPO_ROOT}/profiles/"*.json; do
    name=$(basename "$pf" .json)
    [[ "$name" == "_schema" ]] && continue
    run bash "$INSPECT" "$name" --user-root "$UR"
    [ "$status" -eq 0 ]
    if echo "$output" | grep -Fq "custom hook"; then
      echo "profile $name renders 'custom hook' — a pre_commit id is missing from hook_blurb()"
      echo "$output"
      return 1
    fi
  done
}
