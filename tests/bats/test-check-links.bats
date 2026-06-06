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

# ---- BUG C: percent-encoded + paren targets -------------------------------
# gen-claudemd percent-encodes link targets via nyann::safe_md_link_target
# (space→%20, `(`→%28, `)`→%29). The old check stat'd the raw href, so a
# generated `./target%20file.md` link missed the on-disk `target file.md`
# and flagged gen-claudemd's OWN output as broken. Separately the
# extraction regex `[^)\s]+` truncated a literal-paren target like
# `./file(1).md` to `./file(1`, also a false "broken".

@test "percent-encoded (%20/%28/%29) links to existing files are NOT reported broken" {
  TMP=$(mktemp -d)
  mkdir -p "$TMP/repo/docs"
  # On-disk names carry the DECODED characters.
  echo "x" > "$TMP/repo/docs/target file.md"
  echo "x" > "$TMP/repo/docs/file(1).md"
  cat > "$TMP/repo/CLAUDE.md" <<'MD'
# Project

- [encoded space](./docs/target%20file.md)
- [encoded parens](./docs/file%281%29.md)
MD
  run bash "$CHK" --target "$TMP/repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.broken | length')" -eq 0 ]
  [ "$(echo "$output" | jq '.checked')" -eq 2 ]
  rm -rf "$TMP"
}

@test "literal-paren target ./file(1).md is extracted whole (not truncated) and resolves" {
  TMP=$(mktemp -d)
  mkdir -p "$TMP/repo/docs"
  echo "x" > "$TMP/repo/docs/file(1).md"
  cat > "$TMP/repo/CLAUDE.md" <<'MD'
# Project

- [literal parens](./docs/file(1).md)
MD
  run bash "$CHK" --target "$TMP/repo"
  [ "$status" -eq 0 ]
  # The link must be checked (extraction didn't drop it) and not broken
  # (target extracted as `./docs/file(1).md`, not the truncated
  # `./docs/file(1`).
  [ "$(echo "$output" | jq '.checked')" -eq 1 ]
  [ "$(echo "$output" | jq '.broken | length')" -eq 0 ]
  rm -rf "$TMP"
}

@test "a genuinely missing encoded target is still reported broken" {
  # Decoding must not paper over real breakage: an encoded link whose
  # decoded target does not exist stays broken.
  TMP=$(mktemp -d)
  mkdir -p "$TMP/repo/docs"
  cat > "$TMP/repo/CLAUDE.md" <<'MD'
# Project

- [missing](./docs/no%20such%20file.md)
MD
  run bash "$CHK" --target "$TMP/repo"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.broken | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.broken[0].reason')" = "file-not-found" ]
  rm -rf "$TMP"
}
