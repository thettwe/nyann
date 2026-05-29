#!/usr/bin/env bats
# bin/docs-drift-scan.sh + the 4 detectors (version-refs, file-refs,
# script-refs, count-claims).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-drift.XXXXXX)"
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

@test "version-ref drift: older version ref flagged" {
  cat > "$REPO/README.md" <<'EOF'
# Project
Latest release: v1.0.0
EOF
  ( cd "$REPO" \
      && git add README.md \
      && git commit -q -m "docs: readme" \
      && git tag v1.2.0 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files README.md)
  echo "$out" | jq -e '.findings[] | select(.kind == "version-ref" and .current == "v1.0.0")'
}

@test "version-ref: current version not flagged" {
  cat > "$REPO/README.md" <<'EOF'
# Project
Latest release: v1.2.0
EOF
  ( cd "$REPO" \
      && git add README.md \
      && git commit -q -m "docs: readme" \
      && git tag v1.2.0 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files README.md)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "version-ref: GA ref not flagged when latest tag is a pre-release" {
  # latest tag v1.2.0-rc1 must not make a doc ref to the GA v1.2.0 look stale.
  # The pre-release suffix is stripped before the numeric semver compare.
  cat > "$REPO/README.md" <<'EOF'
# Project
Latest release: v1.2.0
EOF
  ( cd "$REPO" \
      && git add README.md \
      && git commit -q -m "docs: readme" \
      && git tag v1.2.0-rc1 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files README.md)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "version-ref: CHANGELOG.md exempted by default" {
  cat > "$REPO/CHANGELOG.md" <<'EOF'
## [1.0.0]
old release
EOF
  ( cd "$REPO" && git add CHANGELOG.md && git commit -q -m "x" && git tag v2.0.0 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files CHANGELOG.md)
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "file-ref: missing link flagged" {
  cat > "$REPO/README.md" <<'EOF'
# Project
See [docs](docs/missing.md).
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors file-refs --files README.md)
  echo "$out" | jq -e '.findings[] | select(.kind == "file-ref" and .current == "docs/missing.md")'
}

@test "file-ref: existing link not flagged" {
  mkdir -p "$REPO/docs"
  echo "x" > "$REPO/docs/here.md"
  cat > "$REPO/README.md" <<'EOF'
# Project
See [docs](docs/here.md).
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors file-refs --files README.md)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "file-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "file-ref: parenthesised prose (not a markdown link) not flagged" {
  # `Android (AndroidManifest.xml)` is prose, not a [text](link). Only real
  # markdown links (anchored on `](`) should be checked.
  cat > "$REPO/README.md" <<'EOF'
# Project
Detects iOS, Android (AndroidManifest.xml), Flutter (pubspec.yaml here).
Tag pinning (v1.11.0) keeps sources stable.
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors file-refs --files README.md)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "file-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "version-ref: refs inside fenced code blocks not flagged" {
  cat > "$REPO/README.md" <<'EOF'
# Project
```sh
nyann add-source --pin-ref v1.0.0
```
EOF
  ( cd "$REPO" && git add README.md && git commit -q -m "x" && git tag v1.2.0 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files README.md)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "version-ref: explicitly historical refs (pre-vX.Y.Z) not flagged" {
  cat > "$REPO/README.md" <<'EOF'
# Project
This was the default behaviour pre-v1.0.0 and changed since v1.1.0.
EOF
  ( cd "$REPO" && git add README.md && git commit -q -m "x" && git tag v1.2.0 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files README.md)
  count=$(echo "$out" | jq '[.findings[] | select(.kind == "version-ref")] | length')
  [ "$count" -eq 0 ]
}

@test "file-ref: URLs and absolute paths skipped" {
  cat > "$REPO/README.md" <<'EOF'
# Project
[home](https://example.com/foo.html)
[abs](/etc/foo.txt)
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors file-refs --files README.md)
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "script-ref: missing npm script flagged" {
  echo '{"scripts": {"build": "echo build"}}' > "$REPO/package.json"
  cat > "$REPO/README.md" <<'EOF'
# Project
Run with:
```
npm run nonexistent
```
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors script-refs --files README.md)
  echo "$out" | jq -e '.findings[] | select(.kind == "script-ref" and (.current | contains("nonexistent")))'
}

@test "script-ref: valid script not flagged" {
  echo '{"scripts": {"build": "echo b"}}' > "$REPO/package.json"
  cat > "$REPO/README.md" <<'EOF'
# Project
```
npm run build
```
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors script-refs --files README.md)
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "drift-ignore marker suppresses scanning" {
  cat > "$REPO/README.md" <<'EOF'
# Project
v1.0.0 is fine <!-- drift-ignore -->
EOF
  ( cd "$REPO" && git add README.md && git commit -q -m "x" && git tag v9.0.0 )
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors version-refs --files README.md)
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "count-claim: drift detected when tracked_counts configured" {
  mkdir -p "$REPO/tests"
  for i in 1 2 3; do
    : > "$REPO/tests/t$i.bats"
  done
  cat > "$REPO/README.md" <<'EOF'
# Project
We have 99 tests.
EOF
  prof="$TMP/p.json"
  jq -n '{documentation: {drift_check: {enabled: true, count_claims: {enabled: true, tracked_counts: [{keyword: "tests", source: "filesystem-glob", glob: "tests/*.bats"}]}}}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors count-claims --files README.md --profile "$prof")
  echo "$out" | jq -e '.findings[] | select(.kind == "count-claim")'
}

@test "count-claim: silent when not configured" {
  cat > "$REPO/README.md" <<'EOF'
# Project
We have 99 tests.
EOF
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --detectors count-claims --files README.md)
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "master enabled=false short-circuits" {
  cat > "$REPO/README.md" <<'EOF'
# x
[broken](missing.md)
EOF
  prof="$TMP/p.json"
  jq -n '{documentation: {drift_check: {enabled: false}}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --profile "$prof")
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
  echo "$out" | jq -e '.summary.total == 0'
}

@test "Output validates against docs-drift-report schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  cat > "$REPO/README.md" <<'EOF'
# Project
EOF
  bash "$REPO_ROOT/bin/docs-drift-scan.sh" --target "$REPO" --files README.md > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/docs-drift-report.schema.json" "$TMP/r.json"
}
