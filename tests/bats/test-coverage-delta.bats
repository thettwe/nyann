#!/usr/bin/env bats
# bin/guards/coverage-delta.sh + bin/coverage-tools/*.sh — opt-in
# coverage-delta PR guard. Uses fixture coverage ARTIFACTS (and a PATH
# stub for the Go toolchain) — never runs jest/pytest/go/cargo for real.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="$REPO_ROOT/bin/guards/coverage-delta.sh"
  TOOLS="$REPO_ROOT/bin/coverage-tools"
  TMP="$(mktemp -d -t nyann-covdelta.XXXXXX)"
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

# --- fixture helpers ---------------------------------------------------------

# js_artifact <pct> — make REPO a JS project with a coverage summary.
js_artifact() {
  echo '{}' > "$REPO/package.json"
  mkdir -p "$REPO/coverage"
  jq -n --argjson p "$1" '{total:{lines:{pct:$p}}}' > "$REPO/coverage/coverage-summary.json"
}

# py_artifact <rate-0..1> — Python project with a Cobertura coverage.xml.
py_artifact() {
  echo '[tool.pytest]' > "$REPO/pyproject.toml"
  printf '<?xml version="1.0" ?>\n<coverage line-rate="%s" branch-rate="0.8" version="6.0"></coverage>\n' "$1" \
    > "$REPO/coverage.xml"
}

# rust_artifact <rate-0..1> — Rust project with a tarpaulin cobertura.xml.
rust_artifact() {
  echo '[package]' > "$REPO/Cargo.toml"
  printf '<coverage line-rate="%s" version="1"></coverage>\n' "$1" > "$REPO/cobertura.xml"
}

# go_stub <total-pct> — Go project with a coverprofile + a `go` PATH stub
# that emulates `go tool cover -func`. Exports STUBDIR onto PATH.
go_stub() {
  echo 'module x' > "$REPO/go.mod"
  echo 'mode: set' > "$REPO/coverage.out"
  STUBDIR="$TMP/stub"
  mkdir -p "$STUBDIR"
  cat > "$STUBDIR/go" <<EOF
#!/usr/bin/env bash
printf 'x/main.go:1:\tfoo\t100.0%%\n'
printf 'total:\t(statements)\t$1%%\n'
EOF
  chmod +x "$STUBDIR/go"
  PATH="$STUBDIR:$PATH"
}

need_validator() {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator (install check-jsonschema or uvx)"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
}

# --- per-stack artifact parsing ---------------------------------------------

@test "js: parses .total.lines.pct from coverage-summary.json" {
  js_artifact 87.4
  run bash "$TOOLS/js.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "87.4" ]
}

@test "python: parses line-rate from Cobertura coverage.xml (×100)" {
  py_artifact 0.912
  run bash "$TOOLS/python.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "91.2" ]
}

@test "go: parses total from go tool cover -func (stubbed toolchain)" {
  go_stub 76.5
  run bash "$TOOLS/go.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "76.5" ]
}

@test "rust: parses line-rate from tarpaulin cobertura.xml (×100)" {
  rust_artifact 0.6532
  run bash "$TOOLS/rust.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "65.3" ]
}

# --- soft-skip contract ------------------------------------------------------

@test "tool: js soft-skips (non-zero, no output) when no artifact present" {
  echo '{}' > "$REPO/package.json"   # applies, but no coverage/ summary
  run bash "$TOOLS/js.sh" "$REPO"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "guard: no coverage tool/artifact → soft-skip (skipped:true, pass:true)" {
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name == "coverage-delta"'
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.skipped == true'
  echo "$output" | jq -e '.severity == "advisory"'
}

# --- baseline lifecycle ------------------------------------------------------

@test "guard: missing baseline records it and passes" {
  js_artifact 90
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.message | test("baseline recorded")'
  [ -f "$REPO/.nyann/coverage-baseline.json" ]
  echo "recorded:"; cat "$REPO/.nyann/coverage-baseline.json"
  pct=$(jq -r '.coverage_pct' "$REPO/.nyann/coverage-baseline.json")
  [ "$pct" = "90" ]
}

@test "guard: equal coverage passes (advisory, not skipped)" {
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null   # record 90
  run bash "$GUARD" "$REPO" main ""           # re-run at 90
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '(.skipped // false) == false'
}

@test "guard: positive delta passes" {
  js_artifact 80
  bash "$GUARD" "$REPO" main "" >/dev/null   # record 80
  js_artifact 95                              # coverage went up
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
}

@test "guard: negative delta warns (pass:false, severity advisory)" {
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null   # record 90
  js_artifact 80                              # coverage dropped
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]                         # guard never hard-fails
  echo "$output" | jq -e '.pass == false'
  echo "$output" | jq -e '.severity == "advisory"'
  echo "$output" | jq -e '.message | test("dropped")'
}

@test "guard: malformed baseline soft-skips instead of false-warning" {
  js_artifact 90
  mkdir -p "$REPO/.nyann"
  echo '{ not valid json' > "$REPO/.nyann/coverage-baseline.json"
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.skipped == true'
}

# --- profile threshold -------------------------------------------------------

@test "guard: drop within coverage_delta_threshold passes" {
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null   # record 90
  js_artifact 87                              # Δ-3
  echo '{"guards":{"coverage_delta_threshold":5}}' > "$TMP/profile.json"
  run bash "$GUARD" "$REPO" main "$TMP/profile.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.message | test("threshold 5")'
}

@test "guard: drop beyond coverage_delta_threshold still warns" {
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null   # record 90
  js_artifact 80                              # Δ-10
  echo '{"guards":{"coverage_delta_threshold":5}}' > "$TMP/profile.json"
  run bash "$GUARD" "$REPO" main "$TMP/profile.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == false'
}

# --- --update-baseline mode --------------------------------------------------

@test "--update-baseline writes a baseline; absent artifact exits non-zero" {
  # No artifact → nothing to record.
  echo '{}' > "$REPO/package.json"
  run bash "$GUARD" --update-baseline --target "$REPO"
  [ "$status" -ne 0 ]
  [ ! -f "$REPO/.nyann/coverage-baseline.json" ]
  # Add an artifact → records.
  js_artifact 88.8
  run bash "$GUARD" --update-baseline --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "recorded baseline"
  [ -f "$REPO/.nyann/coverage-baseline.json" ]
}

# --- schema validation -------------------------------------------------------

@test "emitted guard fragment validates against guard-result.schema.json" {
  need_validator
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null   # record
  js_artifact 80
  frag=$(bash "$GUARD" "$REPO" main "")        # a failing fragment
  # The guard emits one guards[] item; wrap it in a GuardResult envelope.
  jq -n --argjson g "$frag" '{flow:"pr", pass:false, guards:[$g]}' > "$TMP/gr.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/guard-result.schema.json" "$TMP/gr.json"
}

@test "written coverage-baseline.json validates against its schema" {
  need_validator
  js_artifact 87.4
  bash "$GUARD" --update-baseline --target "$REPO" >/dev/null
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/coverage-baseline.schema.json" \
    "$REPO/.nyann/coverage-baseline.json"
}

# --- end-to-end via pre-action-guard.sh -------------------------------------

@test "pre-action-guard --flow pr invokes coverage-delta when the profile names it" {
  js_artifact 90
  echo '{"guards":{"pr":[{"name":"coverage-delta"}]}}' > "$TMP/profile.json"
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow pr --target "$REPO" --profile "$TMP/profile.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.guards[] | select(.name == "coverage-delta")'
  count=$(echo "$output" | jq '.guards | length')
  [ "$count" -eq 1 ]
}

@test "pre-action-guard: profile promotes coverage-delta to confirm on a drop (exit 4)" {
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null     # record 90
  js_artifact 80                                # drop
  echo '{"guards":{"pr":[{"name":"coverage-delta","severity":"confirm"}]}}' > "$TMP/profile.json"
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow pr --target "$REPO" --profile "$TMP/profile.json"
  [ "$status" -eq 4 ]
  echo "$output" | jq -e '.guards[] | select(.name == "coverage-delta") | .severity == "confirm"'
  echo "$output" | jq -e '.guards[] | select(.name == "coverage-delta") | .pass == false'
}

@test "coverage-delta is OFF by default (absent from built-in pr guards)" {
  js_artifact 90
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow pr --target "$REPO"
  [ "$status" -eq 0 ]
  # No profile → only the built-in pr guards run; coverage-delta must not appear.
  echo "$output" | jq -e '[.guards[] | select(.name == "coverage-delta")] | length == 0'
}

# --- hardening: python never execs repo code -------------------------------

@test "python: never execs repo code; soft-skips on .coverage with no coverage.xml" {
  # Python repo with a cached .coverage data file + a pyproject.toml naming a
  # coverage plugin that would touch a marker, and NO coverage.xml. python.sh
  # must read only the static artifact — never shell out to anything that
  # would import the plugin (which writes the marker).
  marker="$TMP/PWNED"
  cat > "$REPO/pyproject.toml" <<EOF
[tool.coverage.run]
plugins = ["evilplugin"]
EOF
  cat > "$REPO/evilplugin.py" <<EOF
import pathlib
pathlib.Path("$marker").write_text("pwned")
EOF
  : > "$REPO/.coverage"
  # A `coverage` stub on PATH that fails loudly + drops the marker if invoked.
  STUBDIR="$TMP/pystub"; mkdir -p "$STUBDIR"
  cat > "$STUBDIR/coverage" <<EOF
#!/usr/bin/env bash
echo "COVERAGE WAS EXECUTED" >&2
touch "$marker"
printf 'TOTAL\t10\t1\t99%%\n'
exit 0
EOF
  chmod +x "$STUBDIR/coverage"
  PATH="$STUBDIR:$PATH"
  run bash "$TOOLS/python.sh" "$REPO"
  # No coverage.xml → soft-skip (non-zero, no output)...
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # ...and crucially the plugin/coverage was never run.
  [ ! -e "$marker" ]
}

# --- hardening: go toolchain is pinned, suite never runs -------------------

@test "go: pins GOTOOLCHAIN=local, reads existing profile, never runs suite" {
  echo 'module x' > "$REPO/go.mod"
  echo 'mode: set' > "$REPO/coverage.out"
  STUBDIR="$TMP/gostub"; mkdir -p "$STUBDIR"
  ENVLOG="$TMP/go-env.log"; export ENVLOG
  cat > "$STUBDIR/go" <<'EOF'
#!/usr/bin/env bash
{ echo "GOTOOLCHAIN=$GOTOOLCHAIN"; echo "ARGS=$*"; } >> "$ENVLOG"
# Fail loudly if asked to run the suite.
if [[ "$1" == "test" ]]; then echo "SUITE WAS RUN" >> "$ENVLOG"; exit 99; fi
printf 'x/main.go:1:\tfoo\t100.0%%\n'
printf 'total:\t(statements)\t76.5%%\n'
EOF
  chmod +x "$STUBDIR/go"
  PATH="$STUBDIR:$PATH"
  run bash "$TOOLS/go.sh" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "76.5" ]
  grep -q "GOTOOLCHAIN=local" "$ENVLOG"
  grep -q "ARGS=tool cover -func=$REPO/coverage.out" "$ENVLOG"
  ! grep -q "SUITE WAS RUN" "$ENVLOG"
}

# --- hardening: baseline tool must match the detected stack ----------------

@test "guard: baseline tool mismatch (go baseline, js detected) soft-skips" {
  js_artifact 60                             # detected stack = js (60%)
  mkdir -p "$REPO/.nyann"
  # Hand-write a baseline recorded for a DIFFERENT stack (go, 85%).
  jq -n '{tool:"go", coverage_pct:85, recorded_at:"2026-01-01T00:00:00Z"}' \
    > "$REPO/.nyann/coverage-baseline.json"
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.skipped == true'
  echo "$output" | jq -e '.message | test("baseline tool")'
  # No false "dropped 85% → 60%".
  ! echo "$output" | jq -e '.message | test("dropped")'
}

# --- hardening: awk absence soft-skips (never a false drop) ----------------

@test "guard: awk unavailable soft-skips (never false-warns a drop)" {
  js_artifact 90
  bash "$GUARD" "$REPO" main "" >/dev/null   # record 90 (awk present)
  js_artifact 80                             # would be a drop
  # Curated PATH (bash + jq + dirname only) — awk genuinely absent. dirname
  # is needed for the guard's BASH_SOURCE resolution; the awk-skip fires
  # before any coverage tool runs, so nothing else is required.
  NOAWK="$TMP/noawk"; mkdir -p "$NOAWK"
  ln -s "$(command -v bash)"    "$NOAWK/bash"
  ln -s "$(command -v jq)"      "$NOAWK/jq"
  ln -s "$(command -v dirname)" "$NOAWK/dirname"
  OLDPATH="$PATH"
  PATH="$NOAWK"
  run bash "$GUARD" "$REPO" main ""
  PATH="$OLDPATH"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.skipped == true'
  ! echo "$output" | jq -e '.pass == false'
}

# --- hardening: baseline write refuses a pre-planted symlink ---------------

@test "guard: write_baseline refuses a symlinked baseline path (no follow)" {
  js_artifact 90
  mkdir -p "$REPO/.nyann"
  evil="$TMP/evil-target.json"             # dangling (does not yet exist)
  ln -s "$evil" "$REPO/.nyann/coverage-baseline.json"
  run bash "$GUARD" "$REPO" main ""
  [ "$status" -eq 0 ]
  # Guard must soft-skip (write refused) and NOT create the symlink target.
  echo "$output" | jq -e '.pass == true'
  echo "$output" | jq -e '.skipped == true'
  [ ! -e "$evil" ]
}

@test "--update-baseline refuses a symlinked baseline path (no follow)" {
  js_artifact 88
  mkdir -p "$REPO/.nyann"
  evil="$TMP/evil-update.json"
  ln -s "$evil" "$REPO/.nyann/coverage-baseline.json"
  run bash "$GUARD" --update-baseline --target "$REPO"
  [ "$status" -ne 0 ]
  [ ! -e "$evil" ]
}

# --- hardening: numeric awk is locale-pinned -------------------------------

@test "numeric awk is locale-pinned with LC_ALL=C (python, rust, guard)" {
  # python.sh + rust.sh: the line-rate×100 conversion must be C-pinned so a
  # comma-decimal locale can't emit `91,2` and fail the guard's numeric regex.
  grep -q 'LC_ALL=C awk' "$TOOLS/python.sh"
  grep -q 'LC_ALL=C awk' "$TOOLS/rust.sh"
  # guard: both the compare and the delta awk must be C-pinned (≥2).
  n=$(grep -c 'LC_ALL=C awk' "$GUARD")
  [ "$n" -ge 2 ]
}
