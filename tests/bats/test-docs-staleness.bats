#!/usr/bin/env bats
# bin/docs-staleness.sh — flag docs whose correlated sources have churned
# since the doc was last touched.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-stale.XXXXXX)"
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

# Helper: commit a file at a backdated timestamp via GIT_*_DATE.
commit_at() {
  local file="$1" msg="$2" days_ago="$3"
  ( cd "$REPO" \
      && git add "$file" \
      && GIT_AUTHOR_DATE="$(date -v "-${days_ago}d" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${days_ago} days ago" +%Y-%m-%dT%H:%M:%SZ)" \
         GIT_COMMITTER_DATE="$(date -v "-${days_ago}d" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${days_ago} days ago" +%Y-%m-%dT%H:%M:%SZ)" \
         git commit -q -m "$msg" )
}

@test "no docs/ directory: empty findings, exits 0" {
  run bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.summary.stale_count == 0'
  echo "$output" | jq -e '.findings == []'
}

@test "non-git repo: empty findings, exits 0" {
  nogit="$TMP/nogit"
  mkdir -p "$nogit/docs"
  echo "# doc" > "$nogit/docs/architecture.md"
  run bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$nogit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings == []'
}

@test "fresh doc + few source commits: not flagged" {
  mkdir -p "$REPO/docs" "$REPO/src/auth"
  echo "# auth" > "$REPO/docs/auth.md"
  echo "let x;" > "$REPO/src/auth/foo.ts"
  commit_at docs/auth.md "feat: docs" 1
  commit_at src/auth/foo.ts "feat: src" 0
  out=$(bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" --threshold-commits 5 --threshold-days 30)
  echo "$out" | jq -e '.summary.stale_count == 0'
}

@test "stale doc: 5+ source commits after doc untouched" {
  mkdir -p "$REPO/docs" "$REPO/src/auth"
  echo "# auth" > "$REPO/docs/auth.md"
  echo "let x = 1;" > "$REPO/src/auth/foo.ts"
  commit_at docs/auth.md "docs: initial" 60
  commit_at src/auth/foo.ts "feat: initial" 50
  # Now 6 commits to src/auth/* after the doc.
  for i in 1 2 3 4 5 6; do
    echo "let y$i;" > "$REPO/src/auth/file$i.ts"
    commit_at "src/auth/file$i.ts" "feat: $i" $((40 - i))
  done
  out=$(bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" --threshold-commits 5 --threshold-days 30)
  echo "$out" | jq -e '.summary.stale_count >= 1'
  echo "$out" | jq -e '.findings[] | select(.doc == "docs/auth.md")'
}

@test "custom threshold-commits lowers the bar" {
  mkdir -p "$REPO/docs" "$REPO/src/auth"
  echo "# auth" > "$REPO/docs/auth.md"
  echo "let x;" > "$REPO/src/auth/foo.ts"
  commit_at docs/auth.md "docs: initial" 60
  commit_at src/auth/foo.ts "feat: initial" 50
  for i in 1 2; do
    echo "let y$i;" > "$REPO/src/auth/file$i.ts"
    commit_at "src/auth/file$i.ts" "feat: $i" $((40 - i))
  done
  out=$(bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" --threshold-commits 2 --threshold-days 30)
  echo "$out" | jq -e '.summary.stale_count >= 1'
}

@test "profile thresholds are honored" {
  mkdir -p "$REPO/docs" "$REPO/src/auth"
  echo "# auth" > "$REPO/docs/auth.md"
  echo "let x;" > "$REPO/src/auth/foo.ts"
  commit_at docs/auth.md "docs" 60
  commit_at src/auth/foo.ts "feat" 50
  for i in 1 2; do
    echo "let y$i;" > "$REPO/src/auth/f$i.ts"
    commit_at "src/auth/f$i.ts" "f$i" $((40 - i))
  done
  prof="$TMP/p.json"
  jq -n '{documentation: {staleness_threshold_commits: 2, staleness_threshold_days: 30}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" --profile "$prof")
  echo "$out" | jq -e '.thresholds.commits == 2'
  echo "$out" | jq -e '.summary.stale_count >= 1'
}

@test "threshold-commits 0 rejected: falls back to default, schema-valid" {
  # 0 would flag everything and violates the schema (minimum: 1). The guard
  # must clamp it back to the default (5), not pass it through.
  mkdir -p "$REPO/docs" "$REPO/src/auth"
  echo "# auth" > "$REPO/docs/auth.md"
  echo "let x;" > "$REPO/src/auth/foo.ts"
  commit_at docs/auth.md "docs" 1
  commit_at src/auth/foo.ts "feat" 0
  out=$(bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" --threshold-commits 0)
  echo "$out" | jq -e '.thresholds.commits == 5'
  echo "$out" | jq -e '.thresholds.commits >= 1'
}

@test "threshold-days 0 rejected: falls back to default" {
  mkdir -p "$REPO/docs"
  echo "# a" > "$REPO/docs/architecture.md"
  commit_at docs/architecture.md "docs" 1
  out=$(bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" --threshold-days 0)
  echo "$out" | jq -e '.thresholds.days == 30'
  echo "$out" | jq -e '.thresholds.days >= 1'
}

@test "Output validates against docs-staleness schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  bash "$REPO_ROOT/bin/docs-staleness.sh" --target "$REPO" > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/docs-staleness.schema.json" "$TMP/r.json"
}
