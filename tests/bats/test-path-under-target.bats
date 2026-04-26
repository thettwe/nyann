#!/usr/bin/env bats
# nyann::path_under_target / nyann::assert_path_under_target helper tests.
# These are the security primitives that gate bootstrap, scaffold-docs,
# release and sync-team-profiles path handling.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # Source via a tiny harness so we don't trip `set -e` from _lib.sh
  # when a helper returns non-zero.
  HARNESS="$(mktemp -t nyann-path-harness.XXXXXX).sh"
  cat > "$HARNESS" <<EOF
#!/usr/bin/env bash
# shellcheck source=/dev/null
source "${REPO_ROOT}/bin/_lib.sh"
set +o errexit
"\$@"
EOF
  chmod +x "$HARNESS"
  TMP="$(mktemp -d -t nyann-path-td.XXXXXX)"
  # Canonicalise — macOS mktemp returns /var/... which realpath
  # resolves to /private/var/...; assertions need the canonical form.
  TMP="$(cd "$TMP" && pwd -P)"
  mkdir -p "$TMP/repo/sub/nested"
}

teardown() {
  rm -rf "$TMP" "$HARNESS"
}

@test "path_under_target: direct child is accepted" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "$TMP/repo/file.txt" ]]
}

@test "path_under_target: nested descendant is accepted" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/sub/nested/x"
  [ "$status" -eq 0 ]
}

@test "path_under_target: target itself (no subpath) is accepted" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo"
  [ "$status" -eq 0 ]
}

@test "path_under_target: ../escape is rejected" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/../escape"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "path_under_target: deep ../../../etc traversal is rejected" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/sub/../../../etc/passwd"
  [ "$status" -ne 0 ]
}

@test "path_under_target: sibling directory (repo2) is rejected" {
  mkdir -p "$TMP/repo2"
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo2/file"
  [ "$status" -ne 0 ]
}

@test "path_under_target: absolute unrelated path is rejected" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "/etc/passwd"
  [ "$status" -ne 0 ]
}

@test "path_under_target: empty args return 1 without printing" {
  run "$HARNESS" nyann::path_under_target "" ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "path_under_target: symlink escaping target is rejected" {
  # A symlink inside the repo that points outside should be canonicalised
  # to the real target and rejected.
  mkdir -p "$TMP/outside"
  ln -s "$TMP/outside" "$TMP/repo/escape-link"
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/escape-link/secret"
  [ "$status" -ne 0 ]
}

@test "assert_path_under_target: accepts valid path" {
  run "$HARNESS" nyann::assert_path_under_target "$TMP/repo" "$TMP/repo/ok" "test-ctx"
  [ "$status" -eq 0 ]
  [[ "$output" == "$TMP/repo/ok" ]]
}

@test "assert_path_under_target: dies with context on escape" {
  run "$HARNESS" nyann::assert_path_under_target "$TMP/repo" "$TMP/repo/../escape" "plan write path 'x'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"escapes target directory"* ]]
  [[ "$output" == *"plan write path 'x'"* ]]
}

@test "valid_profile_name: accepts lowercase kebab ids" {
  run "$HARNESS" nyann::valid_profile_name "team-acme"
  [ "$status" -eq 0 ]
  run "$HARNESS" nyann::valid_profile_name "default"
  [ "$status" -eq 0 ]
  run "$HARNESS" nyann::valid_profile_name "a1"
  [ "$status" -eq 0 ]
}

@test "valid_profile_name: rejects traversal and weird chars" {
  run "$HARNESS" nyann::valid_profile_name "../evil"
  [ "$status" -ne 0 ]
  run "$HARNESS" nyann::valid_profile_name "foo/bar"
  [ "$status" -ne 0 ]
  run "$HARNESS" nyann::valid_profile_name "Foo"
  [ "$status" -ne 0 ]
  run "$HARNESS" nyann::valid_profile_name "-leading-dash"
  [ "$status" -ne 0 ]
  run "$HARNESS" nyann::valid_profile_name ""
  [ "$status" -ne 0 ]
}
