#!/usr/bin/env bats
# License allowlist scan (bin/license-scan.sh + bin/license-tools/* +
# bin/guards/license-allowlist.sh). Ecosystem tools are PATH stubs; the
# scan itself is filesystem-only. Covers collector normalization (incl.
# scoped-npm-name splitting), OR/AND license semantics, unknown-license
# handling, exemptions, soft-skips, the guard fragments, and the report
# shape.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-lic.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  SCAN="$REPO_ROOT/bin/license-scan.sh"
  GUARD="$REPO_ROOT/bin/guards/license-allowlist.sh"

  # Profile fragment: license-scan only jq-reads .security, so a minimal
  # JSON file stands in for a resolved profile.
  PROFILE="$TMP/profile.json"
  jq -n '{security: {license_check: {enabled: true, allowlist: ["MIT", "Apache-2.0"],
                                     ignore_packages: ["legacy-blob"]}}}' > "$PROFILE"

  # Stub license-checker driven by $LC_FIXTURE.
  STUB="$TMP/stub"
  mkdir -p "$STUB"
  cat > "$STUB/license-checker" <<'SH'
#!/usr/bin/env bash
cat "$LC_FIXTURE"
SH
  chmod +x "$STUB/license-checker"
  export LC_FIXTURE="$TMP/lc.json"
}

teardown() { rm -rf "$TMP"; }

scan() { PATH="$STUB:$PATH" bash "$SCAN" --target "$REPO" --profile "$PROFILE" "$@" 2>/dev/null; }

# js_fixture <pkg@ver> <licenses-json-value> ... (pairs)
js_fixture() {
  local json='{}'
  while (( $# >= 2 )); do
    json=$(jq --arg k "$1" --argjson l "$2" '. + {($k): {licenses: $l}}' <<<"$json")
    shift 2
  done
  printf '%s' "$json" > "$LC_FIXTURE"
  echo '{"name":"x"}' > "$REPO/package.json"
}

@test "disabled profile → enabled:false no-op report, exit 0" {
  jq -n '{}' > "$PROFILE"
  run bash "$SCAN" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  rep=$(echo "$output" | grep -v '^\[nyann\]')
  [ "$(echo "$rep" | jq -r '.enabled')" = "false" ]
}

@test "enabled but no applicable collector → scanned:false, all tools skipped" {
  run scan
  [ "$status" -eq 0 ]
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.scanned')" = "false" ]
  [ "$(echo "$rep" | jq -r '.tools_skipped | length')" = "4" ]
}

@test "js collector: allowed licenses pass, scoped names split on the LAST @" {
  js_fixture "@scope/pkg@1.2.3" '"MIT"' "plain@2.0.0" '"Apache-2.0"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "0" ]
  [ "$(echo "$rep" | jq -r '.packages_total')" = "2" ]
  [ "$(echo "$rep" | jq -r '[.tools_run[]] | index("js") != null')" = "true" ]
}

@test "a license outside the allowlist is a not-allowlisted violation" {
  js_fixture "gplware@1.0.0" '"GPL-3.0"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "1" ]
  [ "$(echo "$rep" | jq -r '.violations[0].reason')" = "not-allowlisted" ]
  [ "$(echo "$rep" | jq -r '.violations[0].package')" = "gplware" ]
}

@test "OR license passes when ANY branch is allowed" {
  js_fixture "dual@1.0.0" '"GPL-3.0 OR MIT"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "0" ]
}

@test "AND license requires EVERY part allowed" {
  js_fixture "conj@1.0.0" '"MIT AND GPL-3.0"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "1" ]
}

@test "license-checker array licenses normalize to OR semantics" {
  js_fixture "multi@1.0.0" '["GPL-3.0", "MIT"]'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "0" ]
}

@test "UNKNOWN / empty licenses are unknown-license violations, never guessed" {
  js_fixture "mystery@1.0.0" '"UNKNOWN"' "blank@1.0.0" '""'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "2" ]
  [ "$(echo "$rep" | jq -r '[.violations[].reason] | unique | join(",")')" = "unknown-license" ]
}

@test "parenthesised license strings are stripped before matching" {
  js_fixture "wrapped@1.0.0" '"(MIT)"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "0" ]
}

@test "ignore_packages exempts by exact name" {
  js_fixture "legacy-blob@0.1.0" '"GPL-3.0"' "other@1.0.0" '"GPL-3.0"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r '.summary.violations')" = "1" ]
  [ "$(echo "$rep" | jq -r '.violations[0].package')" = "other" ]
}

@test "report shape matches the LicenseScanReport schema surface" {
  js_fixture "a@1.0.0" '"GPL-3.0"'
  rep=$(scan)
  [ "$(echo "$rep" | jq -r 'keys - ["enabled","packages_total","scanned","summary","tools_run","tools_skipped","violations"] | length')" = "0" ]
  [ "$(echo "$rep" | jq -r '.violations[0] | keys - ["license","package","reason","tool","version"] | length')" = "0" ]
}

# --- guard -------------------------------------------------------------------

@test "guard: disabled profile → pass with skipped:true" {
  jq -n '{}' > "$PROFILE"
  run bash "$GUARD" "$REPO" main "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
  [ "$(echo "$output" | jq -r '.pass')" = "true" ]
}

@test "guard: enabled but no collector applicable → pass with skipped:true" {
  run env PATH="$STUB:$PATH" bash "$GUARD" "$REPO" main "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped')" = "true" ]
  echo "$output" | jq -r '.message' | grep -q "not installed"
}

@test "guard: violations → pass:false advisory fragment naming offenders" {
  js_fixture "gplware@1.0.0" '"GPL-3.0"'
  run env PATH="$STUB:$PATH" bash "$GUARD" "$REPO" main "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.pass')" = "false" ]
  [ "$(echo "$output" | jq -r '.severity')" = "advisory" ]
  echo "$output" | jq -r '.message' | grep -q "gplware"
}

@test "guard: clean scan → pass:true fragment" {
  js_fixture "fine@1.0.0" '"MIT"'
  run env PATH="$STUB:$PATH" bash "$GUARD" "$REPO" main "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.pass')" = "true" ]
  [ "$(echo "$output" | jq -r 'has("skipped")')" = "false" ]
}
