#!/usr/bin/env bats
# bin/install-hooks.sh — core + jsts + python phase smoke tests.
# Doesn't actually run `npm install` / `pip install` (those are network-heavy).
# Verifies generated files, markers, and idempotency.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL="${REPO_ROOT}/bin/install-hooks.sh"
}

seed_repo() {
  # $1 = source fixture (optional)
  local tmp src
  tmp=$(mktemp -d)
  src="${1:-}"
  if [[ -n "$src" && -d "$src" ]]; then
    cp -r "$src/." "$tmp/"
  fi
  ( cd "$tmp" && git init -q -b main && git -c user.email=t@t -c user.name=t add . >/dev/null 2>&1 || true )
  printf '%s' "$tmp"
}

@test "--core writes commit-msg + pre-commit hooks with markers" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --core
  [ "$status" -eq 0 ]
  [ -f "$tmp/.git/hooks/commit-msg" ]
  [ -f "$tmp/.git/hooks/pre-commit" ]
  grep -q 'nyann-managed-hook' "$tmp/.git/hooks/commit-msg"
  grep -q 'nyann-managed-hook' "$tmp/.git/hooks/pre-commit"
  rm -rf "$tmp"
}

@test "--core is idempotent (byte-identical re-run)" {
  tmp=$(seed_repo)
  bash "$INSTALL" --target "$tmp" --core >/dev/null 2>&1
  before=$(shasum "$tmp/.git/hooks/pre-commit" "$tmp/.git/hooks/commit-msg" | awk '{print $1}' | shasum | awk '{print $1}')
  bash "$INSTALL" --target "$tmp" --core >/dev/null 2>&1
  after=$(shasum "$tmp/.git/hooks/pre-commit" "$tmp/.git/hooks/commit-msg" | awk '{print $1}' | shasum | awk '{print $1}')
  [ "$before" = "$after" ]
  rm -rf "$tmp"
}

@test "--core re-run preserves user edits in installed hooks" {
  # Regression: the marker check only gated the backup step; the write
  # block ran unconditionally, so user tweaks between the first install
  # and a re-install were silently overwritten.
  tmp=$(seed_repo)
  bash "$INSTALL" --target "$tmp" --core >/dev/null 2>&1
  # Append a user-owned line after the marker block. Must be
  # byte-stable across the re-run for this test to be meaningful.
  printf '\n# USER-ADDED LINE — must survive re-install\nexit 0\n' >> "$tmp/.git/hooks/pre-commit"
  bash "$INSTALL" --target "$tmp" --core >/dev/null 2>&1
  grep -Fq '# USER-ADDED LINE — must survive re-install' "$tmp/.git/hooks/pre-commit"
  rm -rf "$tmp"
}

@test "--jsts writes .husky/* + commitlint.config.js + lint-staged in package.json" {
  tmp=$(seed_repo "${REPO_ROOT}/tests/fixtures/jsts-empty")
  run bash "$INSTALL" --target "$tmp" --jsts
  [ "$status" -eq 0 ]
  [ -f "$tmp/.husky/pre-commit" ]
  [ -f "$tmp/.husky/commit-msg" ]
  [ -f "$tmp/commitlint.config.js" ]
  jq -e '.devDependencies.husky' "$tmp/package.json" >/dev/null
  jq -e '.["lint-staged"]' "$tmp/package.json" >/dev/null
  rm -rf "$tmp"
}

@test "--jsts emits structured skip record when node is absent" {
  tmp=$(seed_repo "${REPO_ROOT}/tests/fixtures/jsts-empty")
  # Use a scratch PATH so the test is robust across runner images that may
  # ship node in /usr/bin.
  empty_bin="$tmp/empty-bin"
  mkdir -p "$empty_bin"
  for exe in jq git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum python3 bash; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$empty_bin/$exe" 2>/dev/null || true
  done
  run env -i HOME="$HOME" PATH="$empty_bin" bash "$INSTALL" --target "$tmp" --jsts
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"skipped":"jsts-hooks"'
  rm -rf "$tmp"
}

@test "--python writes .pre-commit-config.yaml" {
  tmp=$(seed_repo "${REPO_ROOT}/tests/fixtures/python-empty")
  run bash "$INSTALL" --target "$tmp" --python --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$tmp/.pre-commit-config.yaml" ]
  grep -Fq 'ruff-pre-commit' "$tmp/.pre-commit-config.yaml"
  grep -Fq 'commitizen' "$tmp/.pre-commit-config.yaml"
  grep -Fq 'gitleaks' "$tmp/.pre-commit-config.yaml"
  rm -rf "$tmp"
}

@test "--python merge preserves user's pinned ruff rev" {
  tmp=$(seed_repo "${REPO_ROOT}/tests/fixtures/python-empty")
  cat > "$tmp/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.1.0
    hooks:
      - id: ruff
YAML
  run bash "$INSTALL" --target "$tmp" --python --no-install-hook
  [ "$status" -eq 0 ]
  # user's rev preserved (v0.1.0), nyann's v0.5.0 not added
  python3 - "$tmp/.pre-commit-config.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
urls = [r.get('repo') for r in d['repos']]
ruffs = [r for r in d['repos'] if r.get('repo') == 'https://github.com/astral-sh/ruff-pre-commit']
assert len(ruffs) == 1, ruffs
assert ruffs[0]['rev'] == 'v0.1.0', ruffs[0]
PY
  rm -rf "$tmp"
}

# ---- pre-push phase ------------------------------------------------------
# install-hooks.sh --pre-push reads --pre-push-hooks <csv> + optionally
# --pre-push-test-cmd <cmd> and writes a marker-bounded
# .git/hooks/pre-push that dispatches to the named hook IDs.

@test "--pre-push with empty hook list → skips with log, no file written" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --pre-push
  [ "$status" -eq 0 ]
  [ ! -f "$tmp/.git/hooks/pre-push" ]
  echo "$output" | grep -F -e "no hooks declared"
  rm -rf "$tmp"
}

@test "--pre-push with tests + custom test cmd → hook runs that command" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "go test ./..."
  [ "$status" -eq 0 ]
  [ -f "$tmp/.git/hooks/pre-push" ]
  [ -x "$tmp/.git/hooks/pre-push" ]
  grep -Fq "nyann-managed-hook: pre-push" "$tmp/.git/hooks/pre-push"
  grep -Fq "go test ./..." "$tmp/.git/hooks/pre-push"
  grep -Fq "_run_tests" "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push with multi-hook CSV → dispatches every entry" {
  tmp=$(seed_repo)
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests,gitleaks-full" --pre-push-test-cmd "npm test" >/dev/null 2>&1
  # Dispatch block must invoke both functions — the earlier CSV-parse
  # had a "drop the last entry" bug due to missing trailing newline.
  grep -Fq "_run_tests" "$tmp/.git/hooks/pre-push"
  grep -Fq "_run_gitleaks_full" "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push with unknown ID warns at install but writes hook for known ones" {
  tmp=$(seed_repo)
  run bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests,nonsense-id,gitleaks-full" --pre-push-test-cmd "npm test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "unknown hook id"
  grep -Fq "_run_tests" "$tmp/.git/hooks/pre-push"
  grep -Fq "_run_gitleaks_full" "$tmp/.git/hooks/pre-push"
  ! grep -Fq "_run_nonsense" "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push with tests but NO --pre-push-test-cmd → hook fails fast at runtime" {
  tmp=$(seed_repo)
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" >/dev/null 2>&1
  # Generated hook should encode the explicit failure for the missing
  # cmd so users notice the misconfiguration the first time they push.
  grep -Fq "no --pre-push-test-cmd" "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push merges into existing user pre-push (backed up + chained)" {
  tmp=$(seed_repo)
  mkdir -p "$tmp/.git/hooks"
  cat > "$tmp/.git/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
echo "user-content"
EOF
  chmod +x "$tmp/.git/hooks/pre-push"
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "npm test" >/dev/null 2>&1
  [ -f "$tmp/.git/hooks/pre-push.pre-nyann" ]
  grep -Fq "user-content" "$tmp/.git/hooks/pre-push.pre-nyann"
  grep -Fq "nyann-managed-hook: pre-push" "$tmp/.git/hooks/pre-push"
  grep -Fq ".git/hooks/pre-push.pre-nyann" "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push re-run preserves user content appended after the END marker" {
  # Content appended after the END marker must survive a re-install
  # byte-for-byte (mirrors the core hook idempotency test).
  tmp=$(seed_repo)
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "npm test" >/dev/null 2>&1
  # Append user content after the END marker (the documented user-edit zone).
  printf '\n# USER CHECK — must survive re-install\necho "user added line"\nexit 0\n' \
    >> "$tmp/.git/hooks/pre-push"
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "npm test" >/dev/null 2>&1
  grep -Fq '# USER CHECK — must survive re-install' "$tmp/.git/hooks/pre-push"
  grep -Fq 'echo "user added line"' "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push re-run with profile change refreshes nyann block but keeps user tail" {
  # If the user changes their profile (e.g. adds gitleaks-full), the
  # nyann block should refresh while user content after END stays put.
  tmp=$(seed_repo)
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "npm test" >/dev/null 2>&1
  printf '\n# USER ENV SETUP\nexport CI_LOCAL=1\n' >> "$tmp/.git/hooks/pre-push"
  bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests,gitleaks-full" --pre-push-test-cmd "npm test" >/dev/null 2>&1
  # User tail preserved.
  grep -Fq '# USER ENV SETUP' "$tmp/.git/hooks/pre-push"
  grep -Fq 'export CI_LOCAL=1' "$tmp/.git/hooks/pre-push"
  # New hook ID added by the profile change.
  grep -Fq '_run_gitleaks_full' "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push legacy single-marker install warns + rewrites cleanly" {
  # Earlier versions of the installer wrote a single-marker hook (no
  # BEGIN/END pair). Re-installing on top of that legacy layout must
  # succeed (rewrite cleanly) and warn the user that content from the
  # old format can't be auto-preserved — there's no boundary marker
  # to extract their additions from.
  tmp=$(seed_repo)
  mkdir -p "$tmp/.git/hooks"
  cat > "$tmp/.git/hooks/pre-push" <<'LEGACY'
#!/usr/bin/env bash
# nyann-managed-hook: pre-push
set -e
echo "old-format content"
exit 0
LEGACY
  chmod +x "$tmp/.git/hooks/pre-push"
  run bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "npm test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -F -e "older nyann (no BEGIN/END markers)"
  # New install has the BEGIN/END marker pair.
  grep -Fq 'nyann-managed-hook: pre-push BEGIN' "$tmp/.git/hooks/pre-push"
  grep -Fq 'nyann-managed-hook: pre-push END' "$tmp/.git/hooks/pre-push"
  rm -rf "$tmp"
}

@test "--pre-push refuses symlinked .git/hooks directory" {
  tmp=$(seed_repo)
  mv "$tmp/.git/hooks" "$tmp/.git/hooks-real"
  ln -s "$tmp/.git/hooks-real" "$tmp/.git/hooks"
  run bash "$INSTALL" --target "$tmp" --pre-push \
    --pre-push-hooks "tests" --pre-push-test-cmd "npm test"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "symlinked"
  rm -rf "$tmp"
}
