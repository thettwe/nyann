#!/usr/bin/env bats
# bin/gen-readme-badges.sh — shields.io badge block generator.

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

@test "--apply refuses to truncate README with orphaned marker_start" {
  echo "MIT License" > "$REPO/LICENSE"
  cat > "$REPO/README.md" <<'EOF'
# Project

<!-- nyann:badges:start -->
(orphaned — no matching end marker because a prior --apply crashed)

## Important content below that must survive
This paragraph must not be lost.
EOF
  run bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "orphaned marker_start"
  # Original content preserved.
  grep -q "Important content below that must survive" "$REPO/README.md"
}

@test "--apply refuses README with duplicate start marker (no data loss)" {
  echo "MIT License" > "$REPO/LICENSE"
  cat > "$REPO/README.md" <<'EOF'
# Project

<!-- nyann:badges:start -->
![old](x)
<!-- nyann:badges:end -->

Content BETWEEN the two blocks must survive.

<!-- nyann:badges:start -->
![dup](y)
<!-- nyann:badges:end -->

Tail content.
EOF
  run bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "more than once"
  # Nothing destroyed.
  grep -q "Content BETWEEN the two blocks must survive" "$REPO/README.md"
  grep -q "Tail content" "$REPO/README.md"
}

@test "--apply preserves an end-marker substring in prose before the block" {
  echo "MIT License" > "$REPO/LICENSE"
  cat > "$REPO/README.md" <<'EOF'
# Project

The closing marker is written `<!-- nyann:badges:end -->` in docs.

<!-- nyann:badges:start -->
![old](x)
<!-- nyann:badges:end -->

Tail content.
EOF
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  # The prose line containing the end-marker substring (before the real
  # block) must NOT be swallowed.
  grep -q "The closing marker is written" "$REPO/README.md"
  grep -q "Tail content" "$REPO/README.md"
  # The real block got replaced with the new badge.
  grep -q "License-MIT" "$REPO/README.md"
  # Old body removed.
  ! grep -q "old" "$REPO/README.md"
}

@test "--apply twice is byte-identical when README lacks trailing newline" {
  echo "MIT License" > "$REPO/LICENSE"
  printf '# Project\n\nNo trailing newline here.' > "$REPO/README.md"
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  sha1=$(shasum "$REPO/README.md" | cut -c1-40)
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  sha2=$(shasum "$REPO/README.md" | cut -c1-40)
  [ "$sha1" = "$sha2" ]
}

@test "--apply follows a single-hop symlink and keeps it a symlink" {
  echo "MIT License" > "$REPO/LICENSE"
  printf '# Real\n' > "$REPO/real.md"
  ( cd "$REPO" && ln -s real.md README.md )
  bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r > /dev/null
  # README.md stays a symlink; the real file got the badge block.
  [ -L "$REPO/README.md" ]
  grep -q "License-MIT" "$REPO/real.md"
  grep -q "# Real" "$REPO/real.md"
}

@test "--apply refuses a README symlink pointing outside the target tree" {
  echo "MIT License" > "$REPO/LICENSE"
  outside="$TMP/outside.md"
  printf '# Outside\n' > "$outside"
  ( cd "$REPO" && ln -s "$outside" README.md )
  run bash "$REPO_ROOT/bin/gen-readme-badges.sh" --target "$REPO" --apply --owner o --repo r
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "escapes target directory"
  # The outside file was not touched.
  ! grep -q "License-MIT" "$outside"
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
