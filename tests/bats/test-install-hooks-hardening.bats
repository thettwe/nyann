#!/usr/bin/env bats
# Regression tests for install-hooks.sh hardening. Covers:
#   - predictable `package.json.nyann.tmp` replaced with mktemp
#   - jq failure leaves original package.json intact
#   - missing commitlint template aborts without partial-writing
#   - existing non-nyann native hook content is preserved (merged)
# Plus the symlink-refusal guards added alongside these fixes.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL="${REPO_ROOT}/bin/install-hooks.sh"
  TMP="$(mktemp -d -t nyann-instharden.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

seed_jsts() {
  local tmp="$TMP/repo"
  cp -r "${REPO_ROOT}/tests/fixtures/jsts-empty/." "$tmp/"
  ( cd "$tmp" && git init -q -b main )
  printf '%s' "$tmp"
}

# ---- no predictable .nyann.tmp path in repo ----------------------------------

@test "jsts phase does not leave package.json.nyann.tmp behind" {
  repo=$(seed_jsts)
  run bash "$INSTALL" --target "$repo" --jsts
  [ "$status" -eq 0 ]
  # The old fixed tmp path must not appear post-run.
  [ ! -e "$repo/package.json.nyann.tmp" ]
}

@test "jsts phase refuses to rewrite package.json via symlink" {
  repo=$(seed_jsts)
  # Replace the fixture package.json with a symlink pointing at a
  # sentinel file outside the repo. A vulnerable install-hooks would
  # `jq "$pkg" > "$tmp_pkg"` then `mv`, clobbering the sentinel.
  sentinel="$TMP/SENTINEL.json"
  printf '{"nyann_should_not_touch":true}\n' > "$sentinel"
  rm "$repo/package.json"
  ln -s "$sentinel" "$repo/package.json"

  run bash "$INSTALL" --target "$repo" --jsts
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  # Sentinel untouched.
  grep -q "nyann_should_not_touch" "$sentinel"
}

# ---- jq failure leaves package.json intact ------------------------------------

@test "jq filter failure leaves package.json intact (no partial write)" {
  # Simulate a jq failure by making the invoked jq binary exit 1
  # unconditionally. We intercept PATH so install-hooks picks up our
  # stub first.
  repo=$(seed_jsts)
  original_pkg_sha=$(shasum "$repo/package.json" | awk '{print $1}')

  stub_bin="$TMP/stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/jq" <<'SH'
#!/usr/bin/env bash
# Deliberately fail — simulates a jq filter that rejects the input.
echo "jq: simulated failure" >&2
exit 2
SH
  chmod +x "$stub_bin/jq"

  # Make sure every other binary install-hooks uses is still reachable.
  # Link the ones we need explicitly.
  for exe in node bash git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum mktemp chmod; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -sf "$src" "$stub_bin/$exe"
  done

  run env -i HOME="$HOME" PATH="$stub_bin" bash "$INSTALL" --target "$repo" --jsts
  [ "$status" -ne 0 ]
  # Package.json bytes unchanged.
  after_sha=$(shasum "$repo/package.json" | awk '{print $1}')
  [ "$original_pkg_sha" = "$after_sha" ]
}

# ---- missing commitlint template aborts cleanly ------------------------------

@test "missing commitlint template aborts without partial-writing commitlint.config.js" {
  repo=$(seed_jsts)
  # Point husky template root at a directory that's missing commitlint.config.js.
  fake_templates="$TMP/fake-templates"
  mkdir -p "$fake_templates"
  cp "${REPO_ROOT}/templates/husky/pre-commit"  "$fake_templates/pre-commit"
  cp "${REPO_ROOT}/templates/husky/commit-msg"  "$fake_templates/commit-msg"
  # Deliberately omit commitlint.config.js.

  # install-hooks resolves templates relative to the script location;
  # override the husky template root via env-style override. The script
  # doesn't expose one, so temporarily stash the file out of the way.
  mv "${REPO_ROOT}/templates/husky/commitlint.config.js" "${REPO_ROOT}/templates/husky/commitlint.config.js.bak"
  trap 'mv "${REPO_ROOT}/templates/husky/commitlint.config.js.bak" "${REPO_ROOT}/templates/husky/commitlint.config.js" 2>/dev/null || true' RETURN

  run bash "$INSTALL" --target "$repo" --jsts
  [ "$status" -ne 0 ]
  [[ "$output" == *"commitlint template missing"* ]]
  # Crucially: no partial commitlint.config.js written.
  [ ! -f "$repo/commitlint.config.js" ]
}

# ---- existing user native hook content is preserved via merge ----------------

@test "--core preserves a user's existing pre-commit content and chains to it" {
  # The merged hook runs the nyann guard FIRST and exec-chains into
  # the user's backed-up script, so a `exit 0` in the user hook can't
  # bypass gitleaks.
  repo="$TMP/core-repo"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main )
  cat > "$repo/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# USER-CUSTOM-HOOK: must survive nyann install
echo "custom pre-commit ran"
exit 0
HOOK
  chmod +x "$repo/.git/hooks/pre-commit"

  run bash "$INSTALL" --target "$repo" --core
  [ "$status" -eq 0 ]
  # Nyann marker is present in the merged hook.
  grep -Fq 'nyann-managed-hook' "$repo/.git/hooks/pre-commit"
  # Backup file retains the user's original content verbatim.
  [ -f "$repo/.git/hooks/pre-commit.pre-nyann" ]
  grep -Fq 'USER-CUSTOM-HOOK: must survive nyann install' "$repo/.git/hooks/pre-commit.pre-nyann"
  # The merged hook exec-chains into the backup so user's logic runs.
  grep -Eq 'exec .+pre-commit\.pre-nyann' "$repo/.git/hooks/pre-commit"
}

@test "--core refuses to merge if destination is a symlink" {
  repo="$TMP/core-sym"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main )
  sentinel="$TMP/SENTINEL-hook.sh"
  printf '#!/bin/sh\necho nyann_should_not_touch\n' > "$sentinel"
  chmod +x "$sentinel"
  ln -s "$sentinel" "$repo/.git/hooks/pre-commit"

  run bash "$INSTALL" --target "$repo" --core
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  # Sentinel untouched.
  grep -q "nyann_should_not_touch" "$sentinel"
}

# ---- Two-phase commit: assembly failure leaves no half-installed state ----
# install_jsts_phase uses a two-phase commit pattern on the husky hook
# set: assemble every hook into a temp path first, then mv each one
# into place only after assembly succeeded for the WHOLE set. A
# failure during assembly must leave no .husky/* file written —
# otherwise the user could end up with an active pre-commit hook and
# a missing commit-msg hook, which silently weakens enforcement.

@test "--jsts: missing commit-msg template leaves NO half-installed husky state" {
  repo=$(seed_jsts)
  # Build a husky template root that has pre-commit + commitlint.config.js
  # (so the script reaches the husky-hook loop) but is missing commit-msg
  # so the assembly phase fails on the SECOND iteration. Without the
  # two-phase split, assembly's mv on iteration 1 would land
  # .husky/pre-commit before iteration 2 died.
  fake_husky="$TMP/fake-husky"
  mkdir -p "$fake_husky"
  cp "${REPO_ROOT}/templates/husky/pre-commit"          "$fake_husky/pre-commit"
  cp "${REPO_ROOT}/templates/husky/commitlint.config.js" "$fake_husky/commitlint.config.js"
  # commit-msg deliberately absent — this is what triggers the failure.

  run bash "$INSTALL" --target "$repo" --jsts \
    --husky-template-root "$fake_husky"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "husky template missing"
  # The critical assertion: neither hook lands in the target. The
  # assembly failure on commit-msg fires before the publish loop runs,
  # so .husky/ stays empty.
  [ ! -f "$repo/.husky/pre-commit" ]
  [ ! -f "$repo/.husky/commit-msg" ]
}
