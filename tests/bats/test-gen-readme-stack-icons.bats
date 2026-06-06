#!/usr/bin/env bats
# bin/gen-readme-stack-icons.sh — skillicons.dev tech-stack block generator.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-icons.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

@test "typescript stack emits ts icon" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  out=$(bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack")
  echo "$out" | jq -e '.lines | index("ts")'
  echo "$out" | jq -e '.lines | index("react")'
  echo "$out" | jq -e '.rendered | contains("skillicons.dev/icons?i=ts,react")'
}

@test "python stack emits py icon" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"python", framework:"fastapi", secondary_languages:[], package_managers:[]}' > "$stack"
  out=$(bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack")
  echo "$out" | jq -e '.lines | index("py")'
  echo "$out" | jq -e '.lines | index("fastapi")'
}

@test "include adds extra slugs; exclude removes them" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  prof="$TMP/p.json"
  jq -n '{documentation: {readme_stack_icons: {enabled: true, include: ["docker"], exclude: ["react"]}}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --profile "$prof")
  echo "$out" | jq -e '.lines | index("docker")'
  count_react=$(echo "$out" | jq '[.lines[] | select(. == "react")] | length')
  [ "$count_react" -eq 0 ]
}

@test "master enabled=false suppresses block body" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  prof="$TMP/p.json"
  jq -n '{documentation: {readme_stack_icons: {enabled: false}}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --profile "$prof")
  # marker block still emitted, but no skillicons URL.
  echo "$out" | jq -e '.rendered | contains("nyann:stack-icons:start")'
  count=$(echo "$out" | jq '[.rendered | contains("skillicons.dev/icons")] | .[0]')
  [ "$count" = "false" ]
}

@test "--apply writes the block into README.md and is idempotent" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply > /dev/null
  grep -q "nyann:stack-icons:start" "$REPO/README.md"
  grep -q "skillicons.dev/icons?i=ts,react" "$REPO/README.md"
  sha1=$(shasum "$REPO/README.md" | cut -c1-40)
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply > /dev/null
  sha2=$(shasum "$REPO/README.md" | cut -c1-40)
  [ "$sha1" = "$sha2" ]
}

@test "--apply refuses README with duplicate start marker (no data loss)" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  cat > "$REPO/README.md" <<'EOF'
# Project

<!-- nyann:stack-icons:start -->
old
<!-- nyann:stack-icons:end -->

Content BETWEEN the two blocks must survive.

<!-- nyann:stack-icons:start -->
dup
<!-- nyann:stack-icons:end -->

Tail content.
EOF
  run bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "more than once"
  grep -q "Content BETWEEN the two blocks must survive" "$REPO/README.md"
  grep -q "Tail content" "$REPO/README.md"
}

@test "--apply preserves an end-marker substring in prose before the block" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  cat > "$REPO/README.md" <<'EOF'
# Project

The closing marker is written `<!-- nyann:stack-icons:end -->` in docs.

<!-- nyann:stack-icons:start -->
old
<!-- nyann:stack-icons:end -->

Tail content.
EOF
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply > /dev/null
  grep -q "The closing marker is written" "$REPO/README.md"
  grep -q "Tail content" "$REPO/README.md"
  grep -q "skillicons.dev/icons?i=ts,react" "$REPO/README.md"
  ! grep -qx "old" "$REPO/README.md"
}

@test "--apply twice is byte-identical when README lacks trailing newline" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  printf '# Project\n\nNo trailing newline here.' > "$REPO/README.md"
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply > /dev/null
  sha1=$(shasum "$REPO/README.md" | cut -c1-40)
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply > /dev/null
  sha2=$(shasum "$REPO/README.md" | cut -c1-40)
  [ "$sha1" = "$sha2" ]
}

@test "--apply follows a single-hop symlink and keeps it a symlink" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  printf '# Real\n' > "$REPO/real.md"
  ( cd "$REPO" && ln -s real.md README.md )
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply > /dev/null
  [ -L "$REPO/README.md" ]
  grep -q "skillicons.dev/icons?i=ts,react" "$REPO/real.md"
  grep -q "# Real" "$REPO/real.md"
}

@test "--apply refuses a README symlink pointing outside the target tree" {
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript", framework:"react", secondary_languages:[], package_managers:[]}' > "$stack"
  outside="$TMP/outside.md"
  printf '# Outside\n' > "$outside"
  ( cd "$REPO" && ln -s "$outside" README.md )
  run bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "escapes target directory"
  ! grep -q "skillicons" "$outside"
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
  stack="$TMP/stack.json"
  jq -n '{primary_language:"typescript"}' > "$stack"
  bash "$REPO_ROOT/bin/gen-readme-stack-icons.sh" --target "$REPO" --stack "$stack" > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/readme-badge-block.schema.json" "$TMP/r.json"
}
