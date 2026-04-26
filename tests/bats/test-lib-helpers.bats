#!/usr/bin/env bats
# bin/_lib.sh helpers that aren't tightly coupled to a single bin script.
# Direct coverage for the sanitisation / identity / lock primitives so a
# refactor can't quietly change their contract without surfacing in CI.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LIB="${REPO_ROOT}/bin/_lib.sh"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

# `git config user.email` / `user.name` can contain CR/LF. Without
# stripping, those bytes splice into `--author="NAME <EMAIL>"`
# downstream, producing a malformed commit author.
@test "resolve_identity strips CR/LF from git config values" {
  ( cd "$TMP" && git init -q -b main )
  # Use bash's $'…' form to smuggle a literal newline into the value.
  git -C "$TMP" config user.email $'foo\nbar@example.com'
  git -C "$TMP" config user.name  $'line1\nline2'

  # Source the lib in a subshell, invoke resolve_identity, and dump
  # the resulting globals so we can eyeball their byte shape.
  out=$(bash -c "source '$LIB'; nyann::resolve_identity '$TMP'; printf 'E=%s\nN=%s\n' \"\$NYANN_GIT_EMAIL\" \"\$NYANN_GIT_NAME\"")
  [ "$(printf '%s' "$out" | grep -c '^E=')" -eq 1 ]
  [ "$(printf '%s' "$out" | grep -c '^N=')" -eq 1 ]

  email=$(printf '%s' "$out" | sed -n 's/^E=//p')
  name=$(printf '%s' "$out"  | sed -n 's/^N=//p')
  [ "$email" = "foobar@example.com" ]
  [ "$name"  = "line1line2" ]
}

@test "resolve_identity falls back to nyann@local when git config is empty" {
  ( cd "$TMP" && git init -q -b main )
  # Unset both values so the function must fall back. Use
  # --local-only-file to avoid touching the caller's global git config.
  git -C "$TMP" config --unset-all user.email 2>/dev/null || true
  git -C "$TMP" config --unset-all user.name  2>/dev/null || true

  out=$(bash -c "source '$LIB'; HOME='$TMP'/no-home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null nyann::resolve_identity '$TMP'; printf 'E=%s\nN=%s\n' \"\$NYANN_GIT_EMAIL\" \"\$NYANN_GIT_NAME\"")
  email=$(printf '%s' "$out" | sed -n 's/^E=//p')
  name=$(printf '%s' "$out"  | sed -n 's/^N=//p')
  [ "$email" = "nyann@local" ]
  [ "$name"  = "nyann" ]
}

# `nyann::lock` records `<pid> <host>` in `$lockdir/owner` on acquire,
# and surfaces it in the die message on timeout so an operator triaging
# a stuck lock knows which process to kill. `nyann::unlock` removes the
# owner file before `rmdir` so the normal release path still works.
@test "lock timeout message includes held-by owner info" {
  LOCK="$TMP/mylock"
  mkdir "$LOCK"
  printf '%s\n' "99999 fakehost" > "$LOCK/owner"
  out=$(bash -c "source '$LIB'; nyann::lock '$LOCK' 1" 2>&1 || true)
  # Must mention the held-by owner we planted.
  echo "$out" | grep -Fq "held by 99999 fakehost"
  # Must mention the manual-remove hint.
  echo "$out" | grep -Fq "if stale, remove"
}

@test "lock timeout without owner file stays on the plain message" {
  LOCK="$TMP/mylock"
  mkdir "$LOCK"
  # Deliberately no owner file — old locks without owner tracking won't have
  # one. Message should not claim a bogus owner.
  out=$(bash -c "source '$LIB'; nyann::lock '$LOCK' 1" 2>&1 || true)
  echo "$out" | grep -Fq "timed out"
  ! echo "$out" | grep -Fq "held by"
}

@test "acquire writes owner file; unlock removes it and the dir" {
  LOCK="$TMP/mylock"
  bash -c "source '$LIB'; nyann::lock '$LOCK' 1; [[ -f '$LOCK/owner' ]]"
  # Owner file content should look like `<pid> <host>`.
  grep -Eq '^[0-9]+ [^ ]+' "$LOCK/owner"
  # Unlock clears both file and dir.
  bash -c "source '$LIB'; nyann::unlock '$LOCK'"
  [ ! -e "$LOCK" ]
}
