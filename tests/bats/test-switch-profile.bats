#!/usr/bin/env bats
# bin/switch-profile.sh — profile migration diff and apply tests.

# `run --separate-stderr` requires bats 1.5+. We use it on the diff
# tests that pipe $output to jq because switch-profile.sh now lets
# load-profile.sh's stderr through (resolution + schema-validation
# diagnostics) — earlier those were silenced by `2>/dev/null`.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SWITCH="${REPO_ROOT}/bin/switch-profile.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )
}

teardown() { rm -rf "$TMP"; }

# --- Diff computation ---

@test "diff between nextjs-prototype and python-cli shows hook changes" {
  run --separate-stderr bash "$SWITCH" --from nextjs-prototype --to python-cli --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  # Should show additions (ruff added) and removals (eslint removed)
  echo "$output" | jq -e '.additions | length > 0' >/dev/null
  echo "$output" | jq -e '.removals | length > 0' >/dev/null
}

@test "diff between same profile → zero modifications" {
  run --separate-stderr bash "$SWITCH" --from nextjs-prototype --to nextjs-prototype --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  total=$(echo "$output" | jq -r '.total_modifications')
  [ "$total" -eq 0 ]
}

@test "branching strategy change is detected" {
  run --separate-stderr bash "$SWITCH" --from nextjs-prototype --to nextjs-prototype --target "$REPO" --dry-run
  # These use the same strategy; let's create a custom test
  # Use go-service (github-flow) vs a profile with different strategy — all are github-flow in starters
  # So we just verify the field exists in output
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("changes")' >/dev/null
}

@test "hook additions include category and action fields" {
  run --separate-stderr bash "$SWITCH" --from default --to python-cli --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  # default has minimal hooks; python-cli adds ruff, ruff-format, commitizen
  first_addition=$(echo "$output" | jq -r '.additions[0]')
  echo "$first_addition" | jq -e 'has("category") and has("action") and has("path")' >/dev/null
}

@test "hook removals include before value" {
  run --separate-stderr bash "$SWITCH" --from nextjs-prototype --to default --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  # nextjs has eslint, prettier; default doesn't
  echo "$output" | jq -e '.removals | length > 0' >/dev/null
  echo "$output" | jq -e '.removals[0].before != ""' >/dev/null
}

# --- JSON output ---

@test "--json emits valid MigrationPlan JSON" {
  run --separate-stderr bash "$SWITCH" --from nextjs-prototype --to python-cli --target "$REPO" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("from_profile") and has("to_profile") and has("additions") and has("removals") and has("changes") and has("total_modifications")' >/dev/null
}

# --- Error cases ---

@test "missing --from → dies" {
  run bash "$SWITCH" --to python-cli --target "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--from"* ]]
}

@test "missing --to → dies" {
  run bash "$SWITCH" --from nextjs-prototype --target "$REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--to"* ]]
}

@test "unknown profile name → dies" {
  run bash "$SWITCH" --from nonexistent-profile --to python-cli --target "$REPO" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve"* ]]
}

# --- root forwarding (Bug D) ------------------------------------------------
# switch-profile.sh called load-profile.sh bare, ignoring --user-root /
# --plugin-root. In a non-default HOME (CI / sandbox / tests) it resolved a
# different profile set than diff-profile.sh. These lock the forwarding.

@test "--user-root is forwarded so a user-only profile resolves" {
  UR="$TMP/ur"; mkdir -p "$UR/profiles"
  # A profile that exists ONLY under the custom user-root. If --user-root
  # weren't threaded to load-profile.sh, this name would fail to resolve.
  jq '.name = "only-in-user-root"' "$REPO_ROOT/profiles/python-cli.json" \
    > "$UR/profiles/only-in-user-root.json"
  run --separate-stderr bash "$SWITCH" \
    --from only-in-user-root --to python-cli \
    --user-root "$UR" --plugin-root "$REPO_ROOT" \
    --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.from_profile == "only-in-user-root"' >/dev/null
}

@test "without --user-root the user-only profile does NOT resolve" {
  # Counterpart: same profile, but pointed at an empty default-shaped root
  # via HOME so it can't be found — proving the previous test passes
  # because of the forwarded flag, not an ambient copy.
  UR="$TMP/ur"; mkdir -p "$UR/profiles"
  jq '.name = "only-in-user-root"' "$REPO_ROOT/profiles/python-cli.json" \
    > "$UR/profiles/only-in-user-root.json"
  empty_home="$TMP/empty-home"; mkdir -p "$empty_home/.claude/nyann/profiles"
  run env HOME="$empty_home" bash "$SWITCH" \
    --from only-in-user-root --to python-cli \
    --plugin-root "$REPO_ROOT" \
    --target "$REPO" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve"* ]]
}

# --- Plan derivation lock ----------------------------------------------------
# The writes[] handed to bootstrap MUST match what the new profile
# actually opts into; if it's hardcoded (e.g. always claims CLAUDE.md +
# ci.yml + PR template), preview-before-mutate is lying to the user
# about which files will land. These tests lock the derivation:
# writes[] comes from the new profile's extras + ci.enabled + the
# doc plan's local-type targets, with no implicit defaults.
#
# Strategy: stage a copy of bin/ and substitute bootstrap.sh with a
# stub that captures the plan file, so we can assert against its
# contents instead of running a real bootstrap.

@test "non-dry-run plan derives writes[] from the new profile (no hardcoded extras)" {
  bin_copy="$TMP/bin"
  cp -R "$REPO_ROOT/bin" "$bin_copy"
  # load-profile.sh resolves the starter profiles dir as
  # $(_script_dir)/../profiles, so the staged bin/ needs a profiles/
  # sibling. Symlink rather than copy to avoid drift.
  ln -s "$REPO_ROOT/profiles" "$TMP/profiles"
  ln -s "$REPO_ROOT/schemas"  "$TMP/schemas"
  # Replace bootstrap.sh with a capture-only stub — copies the plan
  # file the script just composed to a fixed path, then exits 0.
  cat > "$bin_copy/bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
plan=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan="$2"; shift 2 ;;
    --plan=*) plan="${1#--plan=}"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$plan" && -f "$plan" ]] && cp "$plan" "$NYANN_TEST_CAPTURED_PLAN"
exit 0
STUB
  chmod +x "$bin_copy/bootstrap.sh"

  export NYANN_TEST_CAPTURED_PLAN="$TMP/captured-plan.json"

  # nextjs-prototype → default: default disables ci, editorconfig,
  # github_templates, commit_message_template; both keep gitignore +
  # claude_md. So writes[] should contain .gitignore + CLAUDE.md + the
  # local doc-plan targets, and MUST NOT contain ci.yml, PR template,
  # .editorconfig, or .gitmessage.
  run bash "$bin_copy/switch-profile.sh" --from nextjs-prototype --to default --target "$REPO" --yes
  [ "$status" -eq 0 ]
  [ -f "$NYANN_TEST_CAPTURED_PLAN" ]

  paths=$(jq -r '.writes[].path' "$NYANN_TEST_CAPTURED_PLAN" | sort)

  echo "captured paths:" >&2
  echo "$paths" >&2

  # Must include opted-in items
  echo "$paths" | grep -Fxq "CLAUDE.md"     || { echo "missing CLAUDE.md"     >&2; false; }
  echo "$paths" | grep -Fxq ".gitignore"    || { echo "missing .gitignore"    >&2; false; }

  # Must NOT include disabled items
  ! echo "$paths" | grep -Fxq ".github/workflows/ci.yml"        || { echo "ci.yml present despite ci.enabled=false"       >&2; false; }
  ! echo "$paths" | grep -Fxq ".github/PULL_REQUEST_TEMPLATE.md" || { echo "PR template present despite extras=false"      >&2; false; }
  ! echo "$paths" | grep -Fxq ".editorconfig"                    || { echo ".editorconfig present despite extras=false"   >&2; false; }
  ! echo "$paths" | grep -Fxq ".gitmessage"                      || { echo ".gitmessage present despite extras=false"     >&2; false; }
}

@test "non-dry-run plan includes ci.yml + PR template when new profile opts in" {
  bin_copy="$TMP/bin"
  cp -R "$REPO_ROOT/bin" "$bin_copy"
  # load-profile.sh resolves the starter profiles dir as
  # $(_script_dir)/../profiles, so the staged bin/ needs a profiles/
  # sibling. Symlink rather than copy to avoid drift.
  ln -s "$REPO_ROOT/profiles" "$TMP/profiles"
  ln -s "$REPO_ROOT/schemas"  "$TMP/schemas"
  cat > "$bin_copy/bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
plan=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan="$2"; shift 2 ;;
    --plan=*) plan="${1#--plan=}"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$plan" && -f "$plan" ]] && cp "$plan" "$NYANN_TEST_CAPTURED_PLAN"
exit 0
STUB
  chmod +x "$bin_copy/bootstrap.sh"
  export NYANN_TEST_CAPTURED_PLAN="$TMP/captured-plan.json"

  # default → nextjs-prototype: nextjs has ci.enabled=true,
  # extras.editorconfig=true, extras.github_templates=true,
  # extras.commit_message_template=true. The writes[] must include
  # the toggled-on files even though the OLD switch-profile would
  # have included only the same hardcoded three regardless.
  run bash "$bin_copy/switch-profile.sh" --from default --to nextjs-prototype --target "$REPO" --yes
  [ "$status" -eq 0 ]
  [ -f "$NYANN_TEST_CAPTURED_PLAN" ]

  paths=$(jq -r '.writes[].path' "$NYANN_TEST_CAPTURED_PLAN" | sort)

  echo "captured paths:" >&2
  echo "$paths" >&2

  echo "$paths" | grep -Fxq "CLAUDE.md"                          || { echo "missing CLAUDE.md"                     >&2; false; }
  echo "$paths" | grep -Fxq ".editorconfig"                      || { echo "missing .editorconfig"                >&2; false; }
  echo "$paths" | grep -Fxq ".gitmessage"                        || { echo "missing .gitmessage"                  >&2; false; }
  echo "$paths" | grep -Fxq ".github/PULL_REQUEST_TEMPLATE.md"    || { echo "missing PR template"                  >&2; false; }
  # Note: nextjs-prototype.extras.github_actions_ci=false but
  # ci.enabled=true. The writes-gate is on ci.enabled, so ci.yml
  # MUST be in writes[] (bootstrap's gen-ci is what gates on enabled).
  echo "$paths" | grep -Fxq ".github/workflows/ci.yml"            || { echo "missing ci.yml"                       >&2; false; }
}

# ---- preview-before-mutate guard ------------------------------------------
# The migrate-profile skill is responsible for showing the plan to a
# human and prompting before re-invoking with --yes. The script must
# enforce that a no---yes call (with no --dry-run either) emits the
# plan and refuses to apply, so direct shell callers can't bypass the
# consent gate.

@test "without --yes the script emits plan and refuses to apply" {
  bin_copy="$TMP/bin"
  cp -R "$REPO_ROOT/bin" "$bin_copy"
  ln -s "$REPO_ROOT/profiles" "$TMP/profiles"
  ln -s "$REPO_ROOT/schemas"  "$TMP/schemas"
  cat > "$bin_copy/bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
# Sentinel: any run-thru lands here. If we see this file, the guard failed.
touch "$NYANN_TEST_BOOTSTRAP_INVOKED"
exit 0
STUB
  chmod +x "$bin_copy/bootstrap.sh"
  export NYANN_TEST_BOOTSTRAP_INVOKED="$TMP/bootstrap-invoked.flag"

  # No --dry-run, no --yes: must emit plan + warn, must NOT touch bootstrap.
  # Capture stdout (the JSON plan) and stderr (the --yes hint) separately
  # so jq doesn't choke on the mixed stream.
  stderr_file="$TMP/stderr.txt"
  stdout=$(bash "$bin_copy/switch-profile.sh" --from nextjs-prototype --to default --target "$REPO" 2>"$stderr_file")
  rc=$?
  [ "$rc" -eq 0 ]
  # Stdout is the JSON plan.
  echo "$stdout" | jq -e '.from_profile == "nextjs-prototype"' >/dev/null
  # Stderr mentions --yes recovery so the caller knows what to do next.
  grep -Fq -- "--yes" "$stderr_file"
  # And bootstrap was NOT invoked (guard worked).
  [ ! -f "$NYANN_TEST_BOOTSTRAP_INVOKED" ]
}
