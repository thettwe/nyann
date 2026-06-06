#!/usr/bin/env bats
# bin/claude-hook-block-main.sh — bypass-prevention regressions. The
# previous grep-based parser missed:
#   - `git -C /path commit` / `git -c k=v commit` (global options
#     between `git` and the subcommand)
#   - `--no-verify` anywhere in the string bypassed even when not
#     positional to the commit/push subcommand
#   - branch was always checked against cwd, not the `-C` target

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HOOK="${REPO_ROOT}/bin/claude-hook-block-main.sh"
  TMP="$(mktemp -d -t nyann-hookbypass.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  # Repo on main with an initial commit.
  MAIN_REPO="$TMP/main-repo"
  mkdir -p "$MAIN_REPO"
  ( cd "$MAIN_REPO" \
      && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
  # Repo on a feature branch, to serve as a non-main -C target.
  FEAT_REPO="$TMP/feat-repo"
  mkdir -p "$FEAT_REPO"
  ( cd "$FEAT_REPO" \
      && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" \
      && git checkout -q -b feat/x )
}

teardown() { rm -rf "$TMP"; }

# ---- `git -C <path>` bypass is now blocked -----------------------------------

@test "\`git -C <main-repo> commit\` run from outside still blocks" {
  # Previously the regex required commit/push immediately after git;
  # `-C /path` in between made the command invisible to the guard.
  cd "$TMP"
  run bash "$HOOK" "git -C \"$MAIN_REPO\" commit -m 'bypass attempt'"
  [ "$status" -eq 2 ]
}

@test "\`git -C <feat-repo> commit\` does NOT block (branch is feat/x)" {
  # The -C target's branch is what matters, not cwd. This test sits
  # inside a main repo but -C points at a feature-branched repo, so
  # the guard should stay silent.
  cd "$MAIN_REPO"
  run bash "$HOOK" "git -C \"$FEAT_REPO\" commit -m 'ok'"
  [ "$status" -eq 0 ]
}

@test "\`git -c user.email=x commit\` still blocks on main" {
  cd "$MAIN_REPO"
  run bash "$HOOK" 'git -c user.email=t@t commit -m "bypass attempt"'
  [ "$status" -eq 2 ]
}

@test "\`git --git-dir=<repo>/.git commit\` still blocks on main" {
  # `--git-dir` is another global option that breaks the old regex.
  cd "$TMP"
  run bash "$HOOK" "git --git-dir=\"$MAIN_REPO/.git\" --work-tree=\"$MAIN_REPO\" commit -m 'bypass'"
  # Because git -c --git-dir flags behaviour, resolve-branch may or
  # may not report main depending on cwd interactions. The key point
  # is: the parser must identify this as a commit. We accept either
  # exit 2 (blocked) or 0 (branch couldn't be resolved) — but NOT a
  # silent pass via "regex missed the commit".
  #
  # In this fixture the resolved branch is main, so 2 is expected.
  [ "$status" -eq 2 ]
}

# ---- --no-verify must be positional to the commit/push subcommand ------------

@test "\`echo --no-verify; git commit\` on main does NOT bypass" {
  # The old check used `grep -Eq '--no-verify\b'` on the whole command
  # string, so any earlier clause mentioning --no-verify (an echo, a
  # log, a comment) would silently flip the escape hatch.
  cd "$MAIN_REPO"
  run bash "$HOOK" 'echo "--no-verify"; git commit -m "bypass"'
  [ "$status" -eq 2 ]
}

@test "\`git status --no-verify; git commit\` on main does NOT bypass" {
  # --no-verify passed to a different git subcommand shouldn't count.
  # (Note: --no-verify isn't a real flag for `git status`, but a
  # clever attacker will pick one that is, e.g. arbitrary tooling.)
  cd "$MAIN_REPO"
  run bash "$HOOK" 'git log --no-verify; git commit -m "bypass"'
  [ "$status" -eq 2 ]
}

@test "\`git commit --no-verify -m x\` still honours escape hatch" {
  cd "$MAIN_REPO"
  run bash "$HOOK" 'git commit --no-verify -m "emergency"'
  [ "$status" -eq 0 ]
}

@test "quoted string containing 'git commit' does not false-block" {
  cd "$MAIN_REPO"
  # The commit subject literal contains `git commit` — shlex should
  # keep it a single token so the parser doesn't see a second git
  # invocation.
  run bash "$HOOK" 'git commit -m "refactor: the git commit helper"'
  [ "$status" -eq 2 ]  # commit on main IS blocked — but only once, not infinite recursion
}

@test "\`git push\` via -C still blocks on main" {
  cd "$TMP"
  run bash "$HOOK" "git -C \"$MAIN_REPO\" push origin main"
  [ "$status" -eq 2 ]
}

# ---- fallback path (python3 absent) must NOT fail open -----------------------
# The python parser handles --no-verify positionally. When python3 is
# missing the script drops to a grep-based fallback. Previously that
# fallback checked --no-verify against the WHOLE command string, so a
# decoy clause (`echo --no-verify`, `git log --no-verify`) flipped the
# escape hatch and the commit on main slipped through. These tests pin
# the fallback to the SAME clause-scoped semantics.

# Build a sandbox PATH that has every tool the script needs (git, jq,
# bash, sed, grep, cat, …) but deliberately omits python3, forcing the
# fallback branch.
_make_nopython_path() {
  local sandbox="$TMP/nopython-bin"
  mkdir -p "$sandbox"
  local tool
  for tool in git jq bash sed grep cat printf head tr mktemp env dirname; do
    local src
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$sandbox/$tool"
  done
  printf '%s' "$sandbox"
}

@test "fallback (no python3): \`echo --no-verify; git commit\` on main does NOT bypass" {
  cd "$MAIN_REPO"
  local nopy
  nopy="$(_make_nopython_path)"
  PATH="$nopy" run bash "$HOOK" 'echo "--no-verify"; git commit -m "bypass"'
  # Sanity: ensure python3 really was unreachable for the run.
  ! PATH="$nopy" command -v python3 >/dev/null 2>&1
  [ "$status" -eq 2 ]
}

@test "fallback (no python3): \`git log --no-verify; git commit\` on main does NOT bypass" {
  cd "$MAIN_REPO"
  local nopy
  nopy="$(_make_nopython_path)"
  PATH="$nopy" run bash "$HOOK" 'git log --no-verify; git commit -m "bypass"'
  [ "$status" -eq 2 ]
}

@test "fallback (no python3): \`git commit --no-verify\` still honours escape hatch" {
  cd "$MAIN_REPO"
  local nopy
  nopy="$(_make_nopython_path)"
  PATH="$nopy" run bash "$HOOK" 'git commit --no-verify -m "emergency"'
  [ "$status" -eq 0 ]
}

@test "fallback (no python3): plain \`git commit\` on main still blocks" {
  cd "$MAIN_REPO"
  local nopy
  nopy="$(_make_nopython_path)"
  PATH="$nopy" run bash "$HOOK" 'git commit -m "x"'
  [ "$status" -eq 2 ]
}
