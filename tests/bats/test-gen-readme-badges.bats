#!/usr/bin/env bats
# README badges (C3).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-badges.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed \
      && git remote add origin https://github.com/owner/repo.git )
}

teardown() { rm -rf "$TMP"; }

@test "license badge emitted when LICENSE has MIT" {
  echo "MIT License" > "$REPO/LICENSE"
  out=$(bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO")
  echo "$out" | jq -e 'any(.lines[]; contains("License-MIT"))'
}

@test "ci badge emitted when workflow file present" {
  mkdir -p "$REPO/.github/workflows"
  echo "name: ci" > "$REPO/.github/workflows/ci.yml"
  out=$(bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --owner owner --repo repo)
  echo "$out" | jq -e 'any(.lines[]; contains("actions/workflows/ci.yml"))'
}

@test "release badge emitted with owner/repo" {
  out=$(bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --owner owner --repo repo)
  echo "$out" | jq -e 'any(.lines[]; contains("github/v/release/owner/repo"))'
}

@test "tests badge requires profile opt-in" {
  mkdir -p "$REPO/tests/bats"
  : > "$REPO/tests/bats/x.bats"
  out_default=$(bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO")
  count=$(echo "$out_default" | jq '[.lines[] | select(contains("Tests-"))] | length')
  [ "$count" -eq 0 ]
  prof="$TMP/p.json"
  jq -n '{documentation: {readme_badges: {enabled: true, tests: true}}}' > "$prof"
  out_opt=$(bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --profile "$prof")
  echo "$out_opt" | jq -e 'any(.lines[]; contains("Tests-1%20passing"))'
}

@test "master enabled=false suppresses everything" {
  echo "MIT License" > "$REPO/LICENSE"
  prof="$TMP/p.json"
  jq -n '{documentation: {readme_badges: {enabled: false}}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --profile "$prof")
  count=$(echo "$out" | jq '.lines | length')
  [ "$count" -eq 0 ]
}

@test "--apply writes the marker block into README.md" {
  echo "MIT License" > "$REPO/LICENSE"
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  grep -q "nyann:badges:start" "$REPO/README.md"
  grep -q "License-MIT" "$REPO/README.md"
}

@test "--apply is idempotent" {
  echo "MIT License" > "$REPO/LICENSE"
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  sha1=$(shasum "$REPO/README.md" | cut -c1-40)
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  sha2=$(shasum "$REPO/README.md" | cut -c1-40)
  [ "$sha1" = "$sha2" ]
}

@test "Output validates against readme-badge-block schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --owner o --repo r > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/readme-badge-block.schema.json" "$TMP/r.json"
}
