#!/usr/bin/env bats
# Adversarial input sweeps for the path / git-url / git-ref / profile-name
# validators in bin/_lib.sh. These are the primitives every untrusted-input
# code path leans on, so a regression here unlocks RCE or file-write-outside-
# target. The bats cases in test-path-under-target.bats cover the canonical
# accept/reject pairs; this file widens the net with the categories we'd
# want a fuzzer to exercise: encoded chars, control bytes, option-injection
# strings, scheme variants, depth + length extremes, and symlink topologies.
#
# Style note: the inputs are enumerated rather than randomised. bats has no
# seeded RNG so true random inputs would be non-reproducible on failure;
# explicit tables are deterministic and easier to diff when triaging.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  # Harness sources _lib.sh and disables errexit so a non-zero return from
  # a validator surfaces as a normal $status rather than killing the shell.
  HARNESS="$(mktemp -t nyann-fuzz-harness.XXXXXX).sh"
  cat > "$HARNESS" <<EOF
#!/usr/bin/env bash
# shellcheck source=/dev/null
source "${REPO_ROOT}/bin/_lib.sh"
set +o errexit
"\$@"
EOF
  chmod +x "$HARNESS"

  TMP="$(mktemp -d -t nyann-fuzz-td.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  mkdir -p "$TMP/repo/sub/nested" "$TMP/outside" "$TMP/repo/dir with spaces"
}

teardown() { rm -rf "$TMP" "$HARNESS"; }

# ---------------------------------------------------------------------------
# nyann::path_under_target — rejection sweep
# ---------------------------------------------------------------------------
#
# Each entry below is a candidate that MUST be rejected (status != 0, no
# stdout). The cases cover the realistic ways a hostile JSON manifest /
# profile field could try to escape the target root, including the patterns
# nyann::path_under_target's lexical normaliser is responsible for catching.

@test "path_under_target rejects shallow ../escape" {
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/../escape"
  [ "$status" -ne 0 ]; [ -z "$output" ]
}

@test "path_under_target rejects deep ../../../ chains" {
  for depth in 3 5 10 25; do
    rel=""
    for ((i=0;i<depth;i++)); do rel="../$rel"; done
    run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/${rel}etc/passwd"
    [ "$status" -ne 0 ] || { echo "depth=$depth wrongly accepted" >&2; return 1; }
  done
}

@test "path_under_target rejects ..-mixed-with-existing-components" {
  # Each leg crosses an existing directory then escapes via ..; if the
  # normaliser short-circuits on `-e` of the partial path it would miss
  # this. The helper resolves the nearest existing ancestor then collapses
  # the tail; both halves must contribute to the final containment check.
  for cand in \
      "$TMP/repo/sub/../../escape" \
      "$TMP/repo/sub/nested/../../../outside/x" \
      "$TMP/repo/./sub/./../.././../etc"; do
    run "$HARNESS" nyann::path_under_target "$TMP/repo" "$cand"
    [ "$status" -ne 0 ] || { echo "cand=$cand wrongly accepted" >&2; return 1; }
  done
}

@test "path_under_target rejects sibling-prefix collision" {
  # `$TMP/repo-evil` shares the `$TMP/repo` prefix as a string but is a
  # distinct directory. A naive `startswith` check would accept it; the
  # helper appends `/` to disambiguate and must reject this.
  mkdir -p "$TMP/repo-evil"
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo-evil/x"
  [ "$status" -ne 0 ]
}

@test "path_under_target rejects symlink that escapes" {
  ln -sfn "$TMP/outside" "$TMP/repo/escape-link"
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/escape-link/secret"
  [ "$status" -ne 0 ]
}

@test "path_under_target rejects nested-symlink chain that escapes" {
  # link1 -> link2 -> outside. Canonicalisation must follow every hop.
  ln -sfn "$TMP/outside" "$TMP/link2"
  ln -sfn "$TMP/link2"   "$TMP/repo/link1"
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/link1/leak"
  [ "$status" -ne 0 ]
}

@test "path_under_target tolerates a self-referential symlink loop" {
  # The candidate is a path under the loop; the helper should not hang or
  # crash. Either outcome (reject as escape, or accept as inside) is fine
  # so long as the process exits. macOS ships `gtimeout` via coreutils
  # rather than `timeout`; skip cleanly if neither is on PATH (bats runs
  # on both OSes in CI).
  if command -v timeout >/dev/null 2>&1; then
    to=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    to=gtimeout
  else
    skip "no timeout binary available — install coreutils on macOS"
  fi
  ln -sfn "$TMP/repo/loop" "$TMP/repo/loop"
  run "$to" 5 "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/loop/file"
  # 124 = timeout fired = hang = bug. Any other exit (0 or non-zero) is
  # acceptable; we only care that the helper terminates.
  [ "$status" -ne 124 ]
}

# ---------------------------------------------------------------------------
# nyann::path_under_target — literal-character sweep
# ---------------------------------------------------------------------------
#
# Filesystems treat `%`, `?`, `#`, and unicode as ordinary bytes. The
# validator must not decode them — a `repo/%2e%2e/x` segment is a literal
# directory named `%2e%2e`, NOT a traversal. Over-rejecting would break
# real paths (e.g. Obsidian vault names with `#`).

@test "path_under_target accepts literal percent-encoded segments as descendants" {
  for seg in "%2e%2e" "%2F" "%23" "%00" "%"; do
    mkdir -p "$TMP/repo/$seg"
    run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/$seg/file"
    [ "$status" -eq 0 ] || { echo "seg=$seg wrongly rejected" >&2; return 1; }
  done
}

@test "path_under_target accepts paths containing spaces and unicode" {
  mkdir -p "$TMP/repo/ဥပမာ/sub"   # Burmese: "example"
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/dir with spaces/x"
  [ "$status" -eq 0 ]
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/ဥပမာ/sub/file"
  [ "$status" -eq 0 ]
}

@test "path_under_target survives very long paths" {
  # 200 nested 8-char segments ≈ 1800 bytes. Below PATH_MAX (4096 on
  # Linux, 1024 on macOS) but long enough to flush out off-by-one
  # buffer assumptions. macOS PATH_MAX is small so cap at 100.
  segs="aaaaaaaa"
  for _ in $(seq 1 100); do segs="$segs/bbbbbbbb"; done
  run "$HARNESS" nyann::path_under_target "$TMP/repo" "$TMP/repo/$segs"
  [ "$status" -eq 0 ]
}

@test "path_under_target rejects empty / whitespace-only candidates" {
  for cand in "" " " "  "; do
    run "$HARNESS" nyann::path_under_target "$TMP/repo" "$cand"
    [ "$status" -ne 0 ] || { echo "cand='$cand' wrongly accepted" >&2; return 1; }
  done
}

@test "path_under_target rejects empty target" {
  run "$HARNESS" nyann::path_under_target "" "$TMP/repo/x"
  [ "$status" -ne 0 ]
}

@test "path_under_target rejects nonexistent target" {
  # If the target directory itself can't be canonicalised, the helper
  # must not silently accept descendants against the un-resolved string.
  run "$HARNESS" nyann::path_under_target "$TMP/missing-root" "$TMP/missing-root/x"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# nyann::valid_git_url — rejection sweep
# ---------------------------------------------------------------------------
#
# The two attacks the allowlist exists to block: git's `ext::` transport
# (arbitrary-command execution) and leading-dash option injection. Plus
# variants and adjacent schemes that look reasonable but aren't in the
# allowlist (http://, javascript:, data:, ftp://, mailto:).

@test "valid_git_url rejects ext:: transport variants" {
  # The lowercase `ext::` prefix is the actual git-transport RCE vector.
  # `EXT::` (uppercase) is also rejected because the allowlist case
  # only matches lowercase scheme prefixes — this guards against a
  # future "let's add case-insensitive matching" refactor that would
  # silently widen the surface. The valid-ssh-with-literal-`ext::`
  # form (`ssh://host/path/ext::name`) is a separate case below.
  for url in "ext::sh -c whoami" "ext::cmd" "ext::/bin/sh" "EXT::sh -c id"; do
    run "$HARNESS" nyann::valid_git_url "$url"
    [ "$status" -ne 0 ] || { echo "url=$url wrongly accepted" >&2; return 1; }
  done
}

@test "valid_git_url accepts ssh URL whose remote path contains literal ext::" {
  # Only the leading scheme matters — `ext::` further down the path is
  # a literal directory component on the remote, not a transport
  # selector. Rejecting it would be a false positive that broke real
  # mirrors with `ext::*` filenames.
  run "$HARNESS" nyann::valid_git_url "ssh://git@host/path/ext::name"
  [ "$status" -eq 0 ]
}

@test "valid_git_url rejects leading-dash option-injection" {
  for url in \
      "--upload-pack=cmd" \
      "-oProxyCommand=cmd" \
      "-u" \
      "--exec=cmd https://example.com/x.git"; do
    run "$HARNESS" nyann::valid_git_url "$url"
    [ "$status" -ne 0 ] || { echo "url=$url wrongly accepted" >&2; return 1; }
  done
}

@test "valid_git_url rejects http:// (passive-MITM swap risk)" {
  run "$HARNESS" nyann::valid_git_url "http://example.com/x.git"
  [ "$status" -ne 0 ]
}

@test "valid_git_url rejects adjacent non-git schemes" {
  for url in \
      "javascript:alert(1)" \
      "data:text/plain,evil" \
      "ftp://example.com/x.git" \
      "mailto:victim@example.com" \
      "vbscript:msgbox" \
      "rsync://example.com/x"; do
    run "$HARNESS" nyann::valid_git_url "$url"
    [ "$status" -ne 0 ] || { echo "url=$url wrongly accepted" >&2; return 1; }
  done
}

@test "valid_git_url rejects empty and whitespace" {
  for url in "" " " "  "; do
    run "$HARNESS" nyann::valid_git_url "$url"
    [ "$status" -ne 0 ] || { echo "url='$url' wrongly accepted" >&2; return 1; }
  done
}

@test "valid_git_url accepts canonical https / ssh / git / file URLs" {
  for url in \
      "https://github.com/org/repo.git" \
      "https://user@github.com/org/repo.git" \
      "ssh://git@github.com:22/org/repo.git" \
      "git://example.com/org/repo.git" \
      "git@github.com:org/repo.git" \
      "file:///srv/mirror/repo.git"; do
    run "$HARNESS" nyann::valid_git_url "$url"
    [ "$status" -eq 0 ] || { echo "url=$url wrongly rejected" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# nyann::redact_url — credential redaction sweep
# ---------------------------------------------------------------------------
# Same surface as the URL allowlist: if a credential leaks into logs after
# `git fetch` fails, it ends up in the issue body the operator pastes. The
# redactor must catch every embed style we accept.

@test "redact_url strips embedded credentials from every accepted scheme" {
  for pair in \
      "https://token@github.com/org/repo.git|https://***@github.com/org/repo.git" \
      "https://user:pass@github.com/org/repo.git|https://***@github.com/org/repo.git" \
      "ssh://git:secret@github.com/org/repo.git|ssh://***@github.com/org/repo.git" \
      "git://anything@example.com/x|git://***@example.com/x"; do
    input="${pair%%|*}"
    expected="${pair##*|}"
    actual=$("$HARNESS" nyann::redact_url "$input")
    [ "$actual" = "$expected" ] || { echo "in=$input got=$actual want=$expected" >&2; return 1; }
  done
}

@test "redact_url leaves credential-free schemeless / no-auth URLs untouched" {
  # NOTE: `ssh://git@host/...` is NOT in this list. The helper's regex
  # treats anything before `@` after `://` as a credential, so the
  # canonical anonymous-SSH form gets `git` redacted to `***`. That's
  # over-redaction, not under-redaction (still safe for logs) and the
  # `git@host:path` shorthand isn't affected because it lacks `://`.
  # Documented here so a future "fix" doesn't silently leak tokens.
  for url in \
      "https://github.com/org/repo.git" \
      "git@github.com:org/repo.git" \
      "file:///srv/mirror/repo.git" \
      ""; do
    [ "$("$HARNESS" nyann::redact_url "$url")" = "$url" ]
  done
}

# ---------------------------------------------------------------------------
# nyann::valid_git_ref — option-injection + character sweep
# ---------------------------------------------------------------------------

@test "valid_git_ref rejects leading-dash refs" {
  for r in "-rf" "--upload-pack=cmd" "-"; do
    run "$HARNESS" nyann::valid_git_ref "$r"
    [ "$status" -ne 0 ] || { echo "ref=$r wrongly accepted" >&2; return 1; }
  done
}

@test "valid_git_ref rejects refs with shell metacharacters" {
  for r in 'main;rm -rf /' 'main$(id)' 'main`id`' 'main|cat' 'main&id' 'main>x' "main\\nfoo" "main\$IFS" ""; do
    run "$HARNESS" nyann::valid_git_ref "$r"
    [ "$status" -ne 0 ] || { echo "ref=$r wrongly accepted" >&2; return 1; }
  done
}

@test "valid_git_ref accepts canonical branch / tag / sha refs" {
  for r in \
      "main" \
      "refs/heads/main" \
      "v1.9.0" \
      "release/1.9" \
      "feat/abc-123" \
      "78ed0c7291d93e40c51b085850dc669a4c3ab73b" \
      "v1.0.0-rc.1"; do
    run "$HARNESS" nyann::valid_git_ref "$r"
    [ "$status" -eq 0 ] || { echo "ref=$r wrongly rejected" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# nyann::valid_profile_name — re-exercise from the fuzz angle
# ---------------------------------------------------------------------------

@test "valid_profile_name rejects traversal / shell / encoding tricks" {
  for n in \
      "../evil" \
      "./evil" \
      "foo/bar" \
      "foo\\bar" \
      "Foo" \
      "-leading-dash" \
      ".hidden" \
      "" \
      "foo bar" \
      'name;rm' \
      'name$(id)' \
      "name%2e%2e" \
      "ဥပမာ" \
      "FOO-BAR"; do
    run "$HARNESS" nyann::valid_profile_name "$n"
    [ "$status" -ne 0 ] || { echo "name=$n wrongly accepted" >&2; return 1; }
  done
}

@test "valid_profile_name accepts the canonical id shapes" {
  for n in "default" "team-acme" "a" "a1" "team1-acme2-ext3"; do
    run "$HARNESS" nyann::valid_profile_name "$n"
    [ "$status" -eq 0 ] || { echo "name=$n wrongly rejected" >&2; return 1; }
  done
}
