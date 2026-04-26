#!/usr/bin/env bats
# bin/check-links.sh against the docs-with-broken-links fixture.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CHK="${REPO_ROOT}/bin/check-links.sh"
  FIX="${REPO_ROOT}/tests/fixtures/docs-with-broken-links"
}

@test "fixture → broken=2, mcp=2, skipped=1" {
  run bash "$CHK" --target "$FIX"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.broken | length')"           -eq 2 ]
  [ "$(echo "$output" | jq '.needs_mcp_verify | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.skipped | length')"          -eq 1 ]
}

@test "broken entries carry a sensible reason (file-not-found or escapes-repo-root)" {
  run bash "$CHK" --target "$FIX"
  [ "$status" -eq 0 ]
  # Every broken entry must have one of the two known reasons.
  echo "$output" | jq -e '.broken | all(.reason == "file-not-found" or .reason == "escapes-repo-root")' >/dev/null
  # The fixture has one file-not-found (api-design.md) and one escape
  # (../missing.md relative to CLAUDE.md escapes the repo root).
  [ "$(echo "$output" | jq '[.broken[] | select(.reason == "file-not-found")] | length')" -eq 1 ]
  [ "$(echo "$output" | jq '[.broken[] | select(.reason == "escapes-repo-root")] | length')" -eq 1 ]
}

@test "mcp entries tag connector obsidian|notion" {
  run bash "$CHK" --target "$FIX"
  [ "$status" -eq 0 ]
  connectors=$(echo "$output" | jq -r '.needs_mcp_verify[].connector' | sort -u | paste -sd, -)
  [ "$connectors" = "notion,obsidian" ]
}

@test "http(s) link is in skipped[] with reason external-web-check-disabled" {
  run bash "$CHK" --target "$FIX"
  [ "$status" -eq 0 ]
  reason=$(echo "$output" | jq -r '.skipped[0].reason')
  [ "$reason" = "external-web-check-disabled" ]
}

@test "output validates against LinkCheckReport schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator available"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)
  tmp=$(mktemp)
  bash "$CHK" --target "$FIX" > "$tmp"
  run "${validator[@]}" --schemafile "${REPO_ROOT}/schemas/link-check-report.schema.json" "$tmp"
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "link escaping the repo root is reported broken (not masked as existing)" {
  # Regression: candidate was built as `$target/$src_dir/$path` and tested
  # with `-e`. A link like `../../outside.md` from docs/ would resolve to
  # a real file outside the repo and be silently reported as not-broken.
  TMP=$(mktemp -d)
  mkdir -p "$TMP/repo/docs/nested"
  # A file outside the repo that the escape would hit.
  mkdir -p "$TMP/outside"
  echo "exists" > "$TMP/outside/gotcha.md"
  # Source doc that tries to escape.
  cat > "$TMP/repo/docs/nested/source.md" <<'MD'
See [the answer](../../../outside/gotcha.md).
MD
  run bash "$CHK" --target "$TMP/repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.broken | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.broken[0].reason')" = "escapes-repo-root" ]
  rm -rf "$TMP"
}

@test "./-prefixed link resolves correctly (not reported broken)" {
  TMP=$(mktemp -d)
  mkdir -p "$TMP/repo/docs"
  echo "target" > "$TMP/repo/docs/target.md"
  cat > "$TMP/repo/docs/source.md" <<'MD'
See [target](./target.md).
MD
  run bash "$CHK" --target "$TMP/repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.broken | length')" -eq 0 ]
  rm -rf "$TMP"
}
