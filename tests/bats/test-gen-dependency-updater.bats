#!/usr/bin/env bats
# bin/gen-dependency-updater.sh — Dependabot YAML / Renovate JSON
# generation, preview-then-apply, idempotency, diff-on-conflict.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-dependency-updater.sh"
  TMP=$(mktemp -d)
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# Helpers --------------------------------------------------------------------

yaml_valid() {
  python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$1" >/dev/null 2>&1
}

json_valid() {
  python3 -c "import sys, json; json.load(open(sys.argv[1]))" "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "rejects missing --updater" {
  run bash "$GEN" --ecosystem npm
  [ "$status" -ne 0 ]
  # `--` separator: BSD grep on macOS parses `--updater` as an unknown
  # flag without it. Asserting on the unprefixed substring is enough
  # to discriminate from other failure modes.
  echo "$output" | grep -qF -- "updater"
}

@test "rejects unknown updater value" {
  run bash "$GEN" --updater bogus --ecosystem npm
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "dependabot"
}

@test "rejects missing --ecosystem" {
  run bash "$GEN" --updater dependabot
  [ "$status" -ne 0 ]
  # `--` separator: macOS grep flags `--ecosystem` as an unknown option
  # otherwise. The actual error string is just "ecosystem", which is
  # enough to disambiguate from other failure modes.
  echo "$output" | grep -qF -- "ecosystem"
}

@test "rejects out-of-allowlist ecosystem" {
  run bash "$GEN" --updater dependabot --ecosystem haskell
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "unknown ecosystem"
}

@test "rejects --directory not starting with /" {
  run bash "$GEN" --updater dependabot --directory "packages/api" --ecosystem npm
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "/"
}

@test "rejects --open-prs out of 1..25" {
  run bash "$GEN" --updater dependabot --ecosystem npm --open-prs 50
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "1-25"
}

@test "rejects unknown --grouping" {
  run bash "$GEN" --updater dependabot --ecosystem npm --grouping bundle-everything
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "off"
}

# ---------------------------------------------------------------------------
# Dependabot rendering
# ---------------------------------------------------------------------------

@test "dependabot preview: single ecosystem renders valid YAML to stdout" {
  bash "$GEN" --updater dependabot --ecosystem npm > "$TMP/out.yml"
  yaml_valid "$TMP/out.yml"
  grep -qF 'package-ecosystem: "npm"' "$TMP/out.yml"
  grep -qF 'directory: "/"' "$TMP/out.yml"
  grep -qF 'interval: "weekly"' "$TMP/out.yml"
  # Default minor-patch grouping emits the bundle key.
  grep -qF 'minor-and-patch:' "$TMP/out.yml"
}

@test "dependabot preview: multiple ecosystems each get a block" {
  bash "$GEN" --updater dependabot --ecosystem npm --ecosystem github-actions > "$TMP/out.yml"
  yaml_valid "$TMP/out.yml"
  # Both ecosystems present.
  grep -qF 'package-ecosystem: "npm"' "$TMP/out.yml"
  grep -qF 'package-ecosystem: "github-actions"' "$TMP/out.yml"
}

@test "dependabot preview: per-ecosystem --directory associates correctly" {
  # --directory before --ecosystem applies to that ecosystem.
  bash "$GEN" --updater dependabot \
    --directory "/packages/api"  --ecosystem npm \
    --directory "/packages/web"  --ecosystem npm > "$TMP/out.yml"
  yaml_valid "$TMP/out.yml"
  grep -qF 'directory: "/packages/api"' "$TMP/out.yml"
  grep -qF 'directory: "/packages/web"' "$TMP/out.yml"
  # Two npm blocks expected (monorepo per-workspace).
  [ "$(grep -c 'package-ecosystem: "npm"' "$TMP/out.yml")" = "2" ]
}

@test "dependabot --grouping off omits the groups block entirely" {
  bash "$GEN" --updater dependabot --ecosystem npm --grouping off > "$TMP/out.yml"
  yaml_valid "$TMP/out.yml"
  ! grep -qF 'groups:' "$TMP/out.yml"
}

@test "dependabot --grouping all bundles every semver tier" {
  bash "$GEN" --updater dependabot --ecosystem npm --grouping all > "$TMP/out.yml"
  yaml_valid "$TMP/out.yml"
  grep -qF 'all-updates:' "$TMP/out.yml"
  grep -qF '"major"' "$TMP/out.yml"
}

@test "dependabot --schedule daily / --open-prs cap reflected in output" {
  bash "$GEN" --updater dependabot --ecosystem npm --schedule daily --open-prs 12 > "$TMP/out.yml"
  yaml_valid "$TMP/out.yml"
  grep -qF 'interval: "daily"' "$TMP/out.yml"
  grep -qF 'open-pull-requests-limit: 12' "$TMP/out.yml"
}

# ---------------------------------------------------------------------------
# Renovate rendering
# ---------------------------------------------------------------------------

@test "renovate preview: emits valid JSON with config:recommended" {
  bash "$GEN" --updater renovate --ecosystem npm > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.extends | index("config:recommended")' "$TMP/out.json" >/dev/null
  jq -e '.labels | contains(["dependencies","automated"])' "$TMP/out.json" >/dev/null
}

@test "renovate --schedule monthly emits the first-of-month cron-prose" {
  bash "$GEN" --updater renovate --ecosystem npm --schedule monthly > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.schedule[0] | contains("first day of the month")' "$TMP/out.json" >/dev/null
}

@test "renovate --schedule daily emits natural-language (not raw cron)" {
  # Regression: an earlier version emitted `* 0-3 * * *` for daily,
  # which Renovate parses as "every minute in the 0-3 hour window" —
  # 240 scans per day rather than one. Renovate's natural-language
  # form is the consistent shape across all three schedule branches.
  bash "$GEN" --updater renovate --ecosystem npm --schedule daily > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.schedule[0] | contains("every day")' "$TMP/out.json" >/dev/null
  # Pin against the raw cron regression specifically.
  ! jq -e '.schedule[0] | test("^\\*")' "$TMP/out.json" >/dev/null
}

@test "renovate --grouping minor-patch emits matching packageRule" {
  bash "$GEN" --updater renovate --ecosystem npm > "$TMP/out.json"
  json_valid "$TMP/out.json"
  jq -e '.packageRules[0].groupName == "minor and patch updates"' "$TMP/out.json" >/dev/null
  jq -e '.packageRules[0].matchUpdateTypes | (contains(["minor"]) and contains(["patch"]))' "$TMP/out.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Apply mode
# ---------------------------------------------------------------------------

@test "preview does not write to the filesystem" {
  bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" >/dev/null
  [ ! -e "$TMP/.github/dependabot.yml" ]
}

@test "apply writes .github/dependabot.yml" {
  bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply >/dev/null
  [ -f "$TMP/.github/dependabot.yml" ]
  yaml_valid "$TMP/.github/dependabot.yml"
}

@test "apply writes renovate.json at the repo root" {
  bash "$GEN" --updater renovate --ecosystem npm --target "$TMP" --apply >/dev/null
  [ -f "$TMP/renovate.json" ]
  json_valid "$TMP/renovate.json"
}

@test "apply rejects --target that doesn't exist" {
  run bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP/missing" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "directory"
}

@test "apply refuses to write through a symlink destination" {
  mkdir -p "$TMP/.github"
  ln -s "/etc/shadow-decoy" "$TMP/.github/dependabot.yml"
  run bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "symlink"
  # Decoy target must not have been created (it shouldn't exist regardless).
  [ ! -f "/etc/shadow-decoy" ]
}

@test "apply refuses when .github ancestor is itself a symlink (escape via mkdir -p)" {
  # Pre-existing symlink at .github → an outside-target directory.
  # `mkdir -p $target/.github` would follow the symlink and write
  # dependabot.yml into the decoy. The shared safe_mkdir_under_target
  # helper detects intermediate-component symlinks and refuses.
  decoy="$TMP/decoy-github"
  mkdir -p "$decoy"
  ln -s "$decoy" "$TMP/.github"

  run bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply
  [ "$status" -ne 0 ]
  # Decoy must not contain the generated file.
  [ ! -f "$decoy/dependabot.yml" ]
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "rerun with identical inputs is a no-op (exit 0, 'unchanged' log)" {
  bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply >/dev/null
  run bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "unchanged"
}

@test "diverged file: refuses overwrite without --force-overwrite (exit 3)" {
  mkdir -p "$TMP/.github"
  printf 'version: 2\nupdates: []\n' > "$TMP/.github/dependabot.yml"
  run bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply
  [ "$status" -eq 3 ]
  # Diff printed to stderr (captured into combined $output by run).
  echo "$output" | grep -qF "differs"
  # File NOT overwritten.
  grep -qF 'updates: []' "$TMP/.github/dependabot.yml"
}

@test "diverged file: --force-overwrite replaces it" {
  mkdir -p "$TMP/.github"
  printf 'version: 2\nupdates: []\n' > "$TMP/.github/dependabot.yml"
  run bash "$GEN" --updater dependabot --ecosystem npm --target "$TMP" --apply --force-overwrite
  [ "$status" -eq 0 ]
  # File now matches the generated output.
  grep -qF 'package-ecosystem: "npm"' "$TMP/.github/dependabot.yml"
  ! grep -qF 'updates: []' "$TMP/.github/dependabot.yml"
}

# ---------------------------------------------------------------------------
# Schema validation of the input contract (round-trip would need a CLI →
# JSON mode; here we just assert the schema metaschema is valid and that
# the ecosystem allowlist matches what the script accepts).
# ---------------------------------------------------------------------------

@test "schema enum matches the script's allowlist" {
  # Pull the enum from the schema; assert each value is accepted by the
  # script (in preview mode, no --apply needed).
  while IFS= read -r eco; do
    run bash "$GEN" --updater dependabot --ecosystem "$eco"
    [ "$status" -eq 0 ] || { echo "ecosystem $eco rejected by script but listed in schema" >&2; return 1; }
  done < <(jq -r '
    .properties.ecosystems.items.properties.ecosystem.enum[]
  ' "${REPO_ROOT}/schemas/dependency-updater-config.schema.json")
}
