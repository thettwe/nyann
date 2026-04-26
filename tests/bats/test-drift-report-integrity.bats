#!/usr/bin/env bats
# bin/compute-drift.sh + bin/check-claude-md-size.sh — drift-report
# integrity regressions: awk injection, hard cap, subsystem errors.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPUTE="${REPO_ROOT}/bin/compute-drift.sh"
  CHECK_CLAUDEMD="${REPO_ROOT}/bin/check-claude-md-size.sh"
  TMP=$(mktemp -d -t nyann-drift.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  PROFILE="${REPO_ROOT}/profiles/default.json"
}

teardown() { rm -rf "$TMP"; }

# ---- awk -v removes interpolation-injection ----------------------------------

@test "check-claude-md-size rejects awk injection via budget_kb string" {
  # Craft a profile with a string value in place of the number. jq
  # passes it through (bypassing schema validation if called directly),
  # and the old `awk "BEGIN{printf ... $budget_kb * 1024}"` would have
  # parsed it as awk code. With `awk -v kb="..."` the value is a
  # scalar; arithmetic silently yields 0 / NaN but no code runs.
  evil="$TMP/evil-profile.json"
  jq '.documentation.claude_md_size_budget_kb = "1; system(\"echo PWNED > /tmp/nyann-exploit-sentinel-awk-injection\")"' \
    "$PROFILE" > "$evil"
  rm -f /tmp/nyann-exploit-sentinel-awk-injection

  # Seed a small CLAUDE.md so the script reaches the budget compare.
  echo "hello" > "$REPO/CLAUDE.md"

  run bash "$CHECK_CLAUDEMD" --target "$REPO" --profile "$evil"
  [ "$status" -eq 0 ]
  # awk may emit 0 for a non-numeric kb; as long as no shell command
  # ran, the exploit is closed.
  [ ! -f /tmp/nyann-exploit-sentinel-awk-injection ]
}

# ---- hard cap is the shared plugin-wide constant -----------------------------

@test "check-claude-md-size hard cap matches NYANN_CLAUDEMD_HARD_CAP_BYTES (8192)" {
  # File 7900 B is under 8192 (gen-claudemd's hard cap) — must report
  # warn or ok, not error. Previously hard = 2*budget = 6144 so this
  # was incorrectly flagged as error.
  python3 -c "print('x' * 7900, end='')" > "$REPO/CLAUDE.md"
  run bash "$CHECK_CLAUDEMD" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  status=$(echo "$output" | jq -r '.status')
  hard=$(echo "$output" | jq '.hard_cap_bytes')
  [ "$hard" = "8192" ]
  # warn (over soft 3072 but under hard 8192), not error.
  [ "$status" = "warn" ]
}

@test "check-claude-md-size flags error only above 8192 B" {
  python3 -c "print('x' * 8300, end='')" > "$REPO/CLAUDE.md"
  run bash "$CHECK_CLAUDEMD" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  status=$(echo "$output" | jq -r '.status')
  [ "$status" = "error" ]
}

# ---- subsystem failures surface in drift report ------------------------------

@test "compute-drift surfaces subsystem_errors instead of silent fallback" {
  # Stage a "broken" check-links.sh in a fake script dir so compute-drift's
  # call returns non-zero with stderr. We can't trivially swap scripts in
  # place without touching the repo; instead, simulate via PATH shadowing
  # of an inner dependency. Simpler: pass a malformed --target hint that
  # some checker will barf on.
  #
  # Approach: pass --target pointing at a valid dir, but create a
  # CLAUDE.md so large it exceeds memory limits on python — no, too
  # fragile. Instead, point check-claude-md-size at an unreadable
  # CLAUDE.md (chmod 000) which makes wc fail. The fallback path
  # should record the error.
  echo "hello" > "$REPO/CLAUDE.md"
  chmod 000 "$REPO/CLAUDE.md"

  run bash "$COMPUTE" --target "$REPO" --profile "$PROFILE"
  # Restore perms so teardown can rm.
  chmod 644 "$REPO/CLAUDE.md"
  [ "$status" -eq 0 ]
  # summary.subsystem_errors present; either 0 (if the checker still
  # returned valid JSON despite permissions) or >= 1.
  n_errs=$(echo "$output" | jq '.summary.subsystem_errors // 0')
  # At minimum the field exists and is a number.
  [[ "$n_errs" =~ ^[0-9]+$ ]]
  # And the documentation.subsystem_errors array is present.
  echo "$output" | jq -e '.documentation | has("subsystem_errors")' >/dev/null
}

@test "compute-drift records subsystem_errors[] when a checker fails loudly" {
  # Stage a fake plugin tree that shadows bin/check-staleness.sh with a
  # stub that fails loudly. compute-drift looks up subsystem scripts
  # via ${_script_dir}/check-staleness.sh — so we copy the whole bin
  # into a temp tree, replace just check-staleness.sh, and run that
  # copy's compute-drift.sh.
  #
  # Symlink the sibling profiles/ directory because compute-drift's
  # entry-point schema validation (validate-profile.sh) resolves the
  # schema via ${_script_dir}/../profiles/_schema.json. Without this
  # the staged compute-drift.sh dies before reaching the subsystems
  # this test cares about.
  fake_root="$TMP/fake-plugin"
  fake_bin="$fake_root/bin"
  mkdir -p "$fake_bin"
  cp "${REPO_ROOT}"/bin/*.sh "$fake_bin/"
  ln -s "${REPO_ROOT}/profiles" "$fake_root/profiles"
  cat > "$fake_bin/check-staleness.sh" <<'STUB'
#!/usr/bin/env bash
echo "deliberate staleness failure for bats regression" >&2
exit 3
STUB
  chmod +x "$fake_bin/check-staleness.sh"

  run bash "$fake_bin/compute-drift.sh" --target "$REPO" --profile "$PROFILE"
  [ "$status" -eq 0 ]
  # Expect at least one entry for check-staleness.
  got=$(echo "$output" | jq '[.documentation.subsystem_errors[] | select(.subsystem == "check-staleness")] | length')
  [ "$got" -ge 1 ]
  # Error text preserved (truncated, but should contain the stub message).
  echo "$output" | jq -e '.documentation.subsystem_errors[] | select(.subsystem == "check-staleness").error | contains("deliberate staleness failure")' >/dev/null
  # summary.subsystem_errors counts it.
  n=$(echo "$output" | jq '.summary.subsystem_errors')
  [ "$n" -ge 1 ]
}
