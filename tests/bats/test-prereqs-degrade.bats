#!/usr/bin/env bats
# Scripts that use python3 should degrade gracefully — never crash — when
# python3 or its deps aren't installed.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d)"

  # Build a sandboxed PATH that omits python3 but keeps every other
  # executable our scripts touch. Reused across the suite.
  EMPTY_BIN="$TMP/empty-bin"
  mkdir -p "$EMPTY_BIN"
  for exe in jq git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum bash date uname perl; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$EMPTY_BIN/$exe" 2>/dev/null || true
  done
}

teardown() { rm -rf "$TMP"; }

@test "check-links emits skip record when python3 is absent" {
  mkdir -p "$TMP/repo/docs"
  echo "See [x](./docs/x.md)" > "$TMP/repo/CLAUDE.md"
  run env -i HOME="$HOME" PATH="$EMPTY_BIN" \
    bash "${REPO_ROOT}/bin/check-links.sh" --target "$TMP/repo"
  [ "$status" -eq 0 ]
  reason=$(echo "$output" | jq -r '.skipped[0].reason')
  [ "$reason" = "python3-missing" ]
  [ "$(echo "$output" | jq -r '.checked')" = "0" ]
}

@test "detect-mcp-docs emits empty available[] when python3 is absent" {
  cp "${REPO_ROOT}/tests/fixtures/mcp-configs/obsidian-available.json" "$TMP/settings.json"
  # bats `run` captures stderr alongside stdout; drop stderr explicitly so
  # the warn line doesn't pollute jq.
  out=$(env -i HOME="$HOME" PATH="$EMPTY_BIN" \
    bash "${REPO_ROOT}/bin/detect-mcp-docs.sh" --settings-path "$TMP/settings.json" 2>/dev/null)
  [ "$(echo "$out" | jq '.available | length')" -eq 0 ]
}

@test "check-claude-md-size still reports size + status without python3" {
  # Bootstrap via real nyann to produce a valid CLAUDE.md, then run the
  # size checker without python3 on the PATH.
  repo="$TMP/b"
  cp -r "${REPO_ROOT}/tests/fixtures/jsts-empty/." "$repo/"
  ( cd "$repo" && git init -q -b main )
  "${REPO_ROOT}/bin/detect-stack.sh" --path "$repo" > "$repo/.stack.json"
  "${REPO_ROOT}/bin/route-docs.sh" --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$repo/.docplan.json"
  # Plan must include CLAUDE.md for bootstrap to materialise it under
  # the preview-before-mutate gate (see test-bootstrap-preview-gates).
  cat > "$repo/.plan.json" <<'JSON'
{"writes":[{"path":"CLAUDE.md","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$repo/.plan.json" --emit-sha256 2>/dev/null)
  "${REPO_ROOT}/bin/bootstrap.sh" \
    --target "$repo" --plan "$repo/.plan.json" --plan-sha256 "$sha" \
    --profile "${REPO_ROOT}/profiles/nextjs-prototype.json" \
    --doc-plan "$repo/.docplan.json" --stack "$repo/.stack.json" \
    --project-name degrade-test > /dev/null 2>&1

  run env -i HOME="$HOME" PATH="$EMPTY_BIN" \
    bash "${REPO_ROOT}/bin/check-claude-md-size.sh" \
    --target "$repo" --profile "${REPO_ROOT}/profiles/nextjs-prototype.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "ok" ]
  [ "$(echo "$output" | jq '.sections | length')" -eq 0 ]  # degraded
  [ "$(echo "$output" | jq '.bytes')" -gt 0 ]              # but size is present
}

@test "bin/check-prereqs.sh --json parses and includes hard + soft rows" {
  run bash "${REPO_ROOT}/bin/check-prereqs.sh" --json
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # 1 is "hard missing"; still valid JSON
  # jq validates the shape.
  echo "$output" | jq -e '.prereqs | type == "array"' >/dev/null
  echo "$output" | jq -e '.prereqs | map(.kind) | contains(["hard"])' >/dev/null
  echo "$output" | jq -e '.prereqs | map(.kind) | contains(["soft"])' >/dev/null
}

@test "bin/check-prereqs.sh human output labels hard + soft sections" {
  run bash "${REPO_ROOT}/bin/check-prereqs.sh"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  echo "$output" | grep -Fq 'hard'
  echo "$output" | grep -Fq 'soft'
  echo "$output" | grep -Fq 'jq'
  echo "$output" | grep -Fq 'git'
}
