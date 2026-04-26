#!/usr/bin/env bats
# bin/detect-stack.sh — JS/TS + Python detection + confidence + schema.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  SCHEMA="${REPO_ROOT}/schemas/stack-descriptor.schema.json"
}

@test "jsts-empty fixture → typescript + next + pnpm" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/jsts-empty"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "typescript" ]
  [ "$fw"   = "next" ]
  [ "$pm"   = "pnpm" ]
}

@test "python-empty fixture → python + fastapi + uv" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/python-empty"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  fw=$(echo "$output" | jq -r '.framework')
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$lang" = "python" ]
  [ "$fw"   = "fastapi" ]
  [ "$pm"   = "uv" ]
}

@test "empty fixture → unknown language, confidence 0" {
  run bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/empty"
  [ "$status" -eq 0 ]
  lang=$(echo "$output" | jq -r '.primary_language')
  conf=$(echo "$output" | jq -r '.confidence')
  [ "$lang" = "unknown" ]
  [ "$conf" = "0.00" ]
}

@test "pnpm-lock wins over package-lock" {
  tmp=$(mktemp -d)
  cp "${REPO_ROOT}/tests/fixtures/jsts-empty/package.json" "$tmp/"
  cp "${REPO_ROOT}/tests/fixtures/jsts-empty/tsconfig.json" "$tmp/"
  echo '{"lockfileVersion":3}' > "$tmp/package-lock.json"
  cp "${REPO_ROOT}/tests/fixtures/jsts-empty/pnpm-lock.yaml" "$tmp/"
  run bash "$DETECT" --path "$tmp"
  [ "$status" -eq 0 ]
  pm=$(echo "$output" | jq -r '.package_manager')
  [ "$pm" = "pnpm" ]
  rm -rf "$tmp"
}

@test "output validates against StackDescriptor schema (jsts + python + empty)" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "need uvx or check-jsonschema installed"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  for fix in empty jsts-empty python-empty; do
    tmp=$(mktemp)
    bash "$DETECT" --path "${REPO_ROOT}/tests/fixtures/${fix}" > "$tmp"
    run "${validator[@]}" --schemafile "$SCHEMA" "$tmp"
    [ "$status" -eq 0 ]
    rm -f "$tmp"
  done
}
