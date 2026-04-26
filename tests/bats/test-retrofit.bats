#!/usr/bin/env bats
# bin/retrofit.sh + bin/compute-drift.sh against the legacy fixture.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RETROFIT="${REPO_ROOT}/bin/retrofit.sh"
  SCHEMA="${REPO_ROOT}/schemas/drift-report.schema.json"
  TMP="$(mktemp -d)"
  cp -r "${REPO_ROOT}/tests/fixtures/legacy-with-drift/." "${TMP}/"
  ( cd "$TMP" && ./seed.sh >/dev/null 2>&1 )
}

teardown() { rm -rf "$TMP"; }

@test "legacy fixture → retrofit --json emits schema-valid report with all three sections populated" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json
  [ "$status" -eq 0 ]
  # Must have non-empty missing/misconfigured/non_compliant_history.
  [ "$(echo "$output" | jq '.summary.missing')"               -gt 0 ]
  [ "$(echo "$output" | jq '.summary.misconfigured')"         -gt 0 ]
  [ "$(echo "$output" | jq '.summary.non_compliant_commits')" -gt 0 ]
}

@test "legacy fixture → retrofit text output names each of the three sections" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --report-only
  [ "$status" -eq 5 ]   # missing hygiene → critical
  echo "$output" | grep -q 'MISSING:'
  echo "$output" | grep -q 'MISCONFIGURED:'
  echo "$output" | grep -q 'NON-COMPLIANT HISTORY'
  echo "$output" | grep -q 'DOCUMENTATION:'
}

@test "legacy fixture → non-compliant history entries are flagged but no rewrite is offered" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --report-only
  # Info-only phrase must be present; no 'rebase' or 'filter-branch' in output.
  echo "$output" | grep -q "informational only"
  ! echo "$output" | grep -Eq 'git rebase|filter-branch'
}

@test "clean repo → exit 0 and no drift detected" {
  clean="$(mktemp -d)"
  mkdir -p "$clean/docs/decisions" "$clean/memory" "$clean/.husky"
  ( cd "$clean" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: init" )
  echo '{}' > "$clean/.husky/pre-commit"
  echo '{}' > "$clean/.husky/commit-msg"
  printf '# test\n' > "$clean/CLAUDE.md"
  printf '# Architecture\n' > "$clean/docs/architecture.md"
  printf '# ADR-000\n' > "$clean/docs/decisions/ADR-000-record-architecture-decisions.md"
  printf '# readme\n' > "$clean/memory/README.md"
  printf '' > "$clean/.gitignore"
  run bash "$RETROFIT" --target "$clean" --profile default --report-only
  rm -rf "$clean"
  # Warnings-only or clean (exit 0 or 4; not critical 5)
  [[ "$status" -eq 0 || "$status" -eq 4 ]]
}

@test "legacy fixture → exit 5 for critical drift" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --report-only
  [ "$status" -eq 5 ]
}

@test "legacy fixture → --json output has documentation section" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'has("documentation")')" = "true" ]
  [ "$(echo "$output" | jq '.documentation | has("claude_md")')" = "true" ]
  [ "$(echo "$output" | jq '.documentation | has("links")')" = "true" ]
}

@test "legacy fixture → --json has subsystem_errors field" {
  run bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'has("summary")')" = "true" ]
  [ "$(echo "$output" | jq '.summary | has("subsystem_errors")')" = "true" ]
}

@test "legacy fixture → drift report validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator available"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  out=$(bash "$RETROFIT" --target "$TMP" --profile nextjs-prototype --json)
  echo "$out" > "$TMP/report.json"
  run "${validator[@]}" --schemafile "$SCHEMA" "$TMP/report.json"
  [ "$status" -eq 0 ]
}
