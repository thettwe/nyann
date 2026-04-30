#!/usr/bin/env bats
# All starter + user-fixture profiles validate via bin/validate-profile.sh.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  VALIDATE="${REPO_ROOT}/bin/validate-profile.sh"
}

@test "starter: default.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/default.json"
  [ "$status" -eq 0 ]
}

@test "starter: nextjs-prototype.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/nextjs-prototype.json"
  [ "$status" -eq 0 ]
}

@test "starter: python-cli.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/python-cli.json"
  [ "$status" -eq 0 ]
}

@test "starter: typescript-library.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/typescript-library.json"
  [ "$status" -eq 0 ]
}

@test "starter: react-vite.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/react-vite.json"
  [ "$status" -eq 0 ]
}

@test "starter: node-api.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/node-api.json"
  [ "$status" -eq 0 ]
}

@test "starter: fastapi-service.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/fastapi-service.json"
  [ "$status" -eq 0 ]
}

@test "starter: django-app.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/django-app.json"
  [ "$status" -eq 0 ]
}

@test "starter: go-service.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/go-service.json"
  [ "$status" -eq 0 ]
}

@test "starter: rust-cli.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/rust-cli.json"
  [ "$status" -eq 0 ]
}

@test "starter: java-spring-boot.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/java-spring-boot.json"
  [ "$status" -eq 0 ]
}

@test "starter: dotnet-api.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/dotnet-api.json"
  [ "$status" -eq 0 ]
}

@test "starter: php-laravel.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/php-laravel.json"
  [ "$status" -eq 0 ]
}

@test "starter: flutter-app.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/flutter-app.json"
  [ "$status" -eq 0 ]
}

@test "starter: ruby-rails.json → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/profiles/ruby-rails.json"
  [ "$status" -eq 0 ]
}

@test "fixture: valid-minimal → exit 0" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/valid-minimal.json"
  [ "$status" -eq 0 ]
}

@test "fixture: invalid-missing-stack → exit 4 + stack error" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/invalid-missing-stack.json"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "'stack' is a required property"
}

@test "validate rejects a malformed JSON file (exit 3)" {
  tmp=$(mktemp)
  echo "{not json" > "$tmp"
  run bash "$VALIDATE" "$tmp"
  [ "$status" -eq 3 ]
  rm -f "$tmp"
}

@test "validate reports missing file (exit 2)" {
  run bash "$VALIDATE" "/tmp/does-not-exist-nyann-test-$$.json"
  [ "$status" -eq 2 ]
}

# Schema strictness regressions: release/documentation fields that flow
# into shell or write paths must be regex-locked. These fixtures encode
# the exact attack shapes (path traversal, option injection, shell
# metachars) so a future schema relaxation surfaces immediately.

@test "fixture: invalid-changelog-traversal → exit 4 (path traversal)" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/invalid-changelog-traversal.json"
  [ "$status" -eq 4 ]
}

@test "fixture: invalid-tag-prefix-injection → exit 4 (option injection)" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/invalid-tag-prefix-injection.json"
  [ "$status" -eq 4 ]
}

@test "fixture: invalid-preferred-mcp-shellmeta → exit 4 (shell metachars)" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/invalid-preferred-mcp-shellmeta.json"
  [ "$status" -eq 4 ]
}

@test "fixture: invalid-workspace-hook-id → exit 4 (path traversal in hook id)" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/invalid-workspace-hook-id.json"
  [ "$status" -eq 4 ]
}

@test "fixture: invalid-workspace-key → exit 4 (workspace key starts with '-')" {
  run bash "$VALIDATE" "${REPO_ROOT}/tests/fixtures/profiles/invalid-workspace-key.json"
  [ "$status" -eq 4 ]
}
