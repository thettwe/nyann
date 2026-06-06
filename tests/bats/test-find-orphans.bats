#!/usr/bin/env bats
# bin/find-orphans.sh + default exclusions + .nyann-ignore extension.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  FIND="${REPO_ROOT}/bin/find-orphans.sh"
  TMP="$(mktemp -d)"
  cp -r "${REPO_ROOT}/tests/fixtures/docs-with-orphans/." "${TMP}/"
}

teardown() { rm -rf "$TMP"; }

@test "fixture → exactly 1 orphan" {
  run bash "$FIND" --target "$TMP"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.orphans | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.orphans[0].path')" = "docs/research/old-competitor.md" ]
}

@test ".nyann-ignore can drop the orphan to 0" {
  echo "old-competitor.md" > "$TMP/.nyann-ignore"
  run bash "$FIND" --target "$TMP"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.orphans | length')" -eq 0 ]
}

@test "READMEs and ADR-*.md are excluded by default" {
  # Add an ADR to the fixture; it should not be flagged.
  mkdir -p "$TMP/docs/decisions"
  echo "# ADR" > "$TMP/docs/decisions/ADR-042-nothing-important.md"
  run bash "$FIND" --target "$TMP"
  [ "$status" -eq 0 ]
  ! echo "$output" | jq -r '.orphans[].path' | grep -q ADR-042
}

@test "last_modified_days_ago is a non-negative integer" {
  run bash "$FIND" --target "$TMP"
  [ "$status" -eq 0 ]
  age=$(echo "$output" | jq '.orphans[0].last_modified_days_ago')
  [ "$age" -ge 0 ]
}

# Regression: when CLAUDE.md is absent and scan_dirs contain no `.md`
# files, the `corpus` array is empty. Under `set -u`, expanding
# `"${corpus[@]}"` aborted the script with "unbound variable" and no
# stdout — which then crashed compute-drift's outer `jq --argjson
# orphans ""` with a cryptic "invalid JSON text" error. The fix is to
# use `${corpus[@]+"${corpus[@]}"}` so the iteration is empty rather
# than fatal. Trigger case: a `memory/` containing only a JSON file
# (e.g. `health.json` written by `doctor --persist`) with no CLAUDE.md
# at the repo root.
@test "empty corpus (no CLAUDE.md, no .md files) returns 0 orphans cleanly" {
  empty="$TMP/empty"
  mkdir -p "$empty/memory"
  printf '{"scores":[],"trend":{"direction":"stable","delta":0,"window_days":7}}\n' \
    > "$empty/memory/health.json"
  run bash "$FIND" --target "$empty"
  [ "$status" -eq 0 ]
  # health.json is in the default-exclusion list (see next test), so
  # scanned counts it (file enumerated) but orphans[] stays empty.
  [ "$(echo "$output" | jq '.orphans | length')" -eq 0 ]
}

# Regression: `doctor --persist` writes memory/health.json on every
# run. Without this exclusion the file would surface as an orphan on
# every subsequent doctor run — pure noise. Default-excluded by
# templates/orphan-exclusions.txt.
@test "health.json is excluded by default (no orphan noise from --persist)" {
  withhealth="$TMP/withhealth"
  mkdir -p "$withhealth/memory" "$withhealth/docs"
  printf '# Project\n' > "$withhealth/CLAUDE.md"
  printf '# Architecture\n' > "$withhealth/docs/architecture.md"
  printf '{"scores":[],"trend":{"direction":"stable","delta":0,"window_days":7}}\n' \
    > "$withhealth/memory/health.json"
  run bash "$FIND" --target "$withhealth"
  [ "$status" -eq 0 ]
  # No orphan should be named health.json.
  ! echo "$output" | jq -r '.orphans[].path' | grep -q "health.json"
}

# ---- perf regression: inverted-index scaling --------------------------------
# The concatenated-corpus + one-awk-pass-per-candidate shape keeps
# find-orphans linear in the corpus size rather than quadratic in the
# number of files. This test plants 200 docs that reference each
# other in a chain (worst case: every candidate has to scan every
# corpus file to confirm it's referenced) and asserts completion in
# well under 30s. A regression to per-file grep loops would not
# finish in CI's budget.

@test "inverted-index scales: 200-doc fixture completes in <30s" {
  big="$TMP/big-fixture"
  mkdir -p "$big/docs" "$big/memory"
  cat > "$big/CLAUDE.md" <<'MD'
# Project
- See [docs/architecture.md](docs/architecture.md) for system overview.
MD
  echo "# Architecture" > "$big/docs/architecture.md"
  # 200 sibling docs that all reference each other in a chain so none
  # are orphans (worst case for the algorithm: every candidate has to
  # scan every corpus file to confirm it's referenced).
  for i in $(seq 1 200); do
    next=$(( i + 1 ))
    cat > "$big/docs/doc-$i.md" <<MD
# Doc $i
See [doc-$next](doc-$next.md) for the next entry.
MD
  done
  start=$(date +%s)
  run bash "$FIND" --target "$big"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  # Every doc-N references doc-(N+1) so chain-orphan count = 0 (only the
  # final doc-200 might be flagged depending on whether it has an
  # outbound reference; we just assert no crash + reasonable time).
  echo "elapsed=${elapsed}s" >&2
  [ "$elapsed" -lt 30 ]
}

# ---- BUG E: substring matching masks orphans -------------------------------
# Reference detection used `index($0, terms[i])` (unanchored substring), so
# a doc whose basename is a substring of another *referenced* filename was
# treated as referenced and never flagged. e.g. `arch.md` is a substring of
# the referenced `search.md`, so a true orphan `arch.md` was hidden. The fix
# requires a word-char boundary (`[A-Za-z0-9_-]`) on both sides of the term;
# `/` and `.` remain boundaries so real path/basename references still match.

@test "substring-named true orphan is reported (arch.md not masked by referenced search.md)" {
  sub="$TMP/substr"
  mkdir -p "$sub/docs"
  cat > "$sub/CLAUDE.md" <<'MD'
# Project
- See [search](./docs/search.md) for details.
MD
  echo "# search" > "$sub/docs/search.md"
  echo "# arch"   > "$sub/docs/arch.md"
  run bash "$FIND" --target "$sub"
  [ "$status" -eq 0 ]
  # arch.md is a TRUE orphan — its name is a substring of the referenced
  # `search.md`, but nothing actually references arch.md.
  echo "$output" | jq -r '.orphans[].path' | grep -qx "docs/arch.md"
  # search.md is genuinely referenced, so it must NOT be an orphan.
  ! echo "$output" | jq -r '.orphans[].path' | grep -qx "docs/search.md"
}

@test "boundary match still recognises ./-prefixed path references (no false orphan)" {
  ref="$TMP/refcheck"
  mkdir -p "$ref/docs"
  cat > "$ref/CLAUDE.md" <<'MD'
# Project
- [architecture](./docs/architecture.md)
MD
  echo "# Architecture" > "$ref/docs/architecture.md"
  run bash "$FIND" --target "$ref"
  [ "$status" -eq 0 ]
  # architecture.md is referenced via a `./`-prefixed path; it must not be
  # flagged just because the boundary check tightened.
  [ "$(echo "$output" | jq '.orphans | length')" -eq 0 ]
}
