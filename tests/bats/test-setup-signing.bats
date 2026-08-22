#!/usr/bin/env bats
# Local commit-signing setup (bin/setup-signing.sh): preview-before-mutate,
# per-mode config sets, original-prior preservation across re-applies,
# byte-for-byte undo, and the mode-aware gh-protect signing audit. gitsign
# is a PATH stub; ssh keys live under a fake HOME.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-sign.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m seed \
      && git remote add origin git@github.com:o/r.git )
  SIGN="$REPO_ROOT/bin/setup-signing.sh"

  FAKE_HOME="$TMP/home"
  mkdir -p "$FAKE_HOME/.ssh"
  echo "ssh-ed25519 AAAA test@key" > "$FAKE_HOME/.ssh/id_ed25519.pub"

  GITSIGN_STUB="$TMP/stub"
  mkdir -p "$GITSIGN_STUB"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GITSIGN_STUB/gitsign"
  chmod +x "$GITSIGN_STUB/gitsign"
}

teardown() { rm -rf "$TMP"; }

cfg() { git -C "$REPO" config --local --get "$1" 2>/dev/null || echo "(unset)"; }
sign() { env HOME="$FAKE_HOME" bash "$SIGN" --target "$REPO" "$@"; }

@test "preview renders the delta, writes nothing, exits 2" {
  run sign --mode ssh
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "gpg.format: (unset) → ssh"
  [ "$(cfg commit.gpgsign)" = "(unset)" ]
  [ ! -f "$REPO/memory/.nyann/signing-setup.json" ]
}

@test "ssh apply sets the four keys with the resolved default key" {
  run sign --mode ssh --apply
  [ "$status" -eq 0 ]
  [ "$(cfg gpg.format)" = "ssh" ]
  [ "$(cfg user.signingkey)" = "$FAKE_HOME/.ssh/id_ed25519.pub" ]
  [ "$(cfg commit.gpgsign)" = "true" ]
  [ "$(cfg tag.gpgsign)" = "true" ]
  [ -f "$REPO/memory/.nyann/signing-setup.json" ]
}

@test "ssh with --key overrides the default; missing key file dies" {
  echo "ssh-ed25519 BBBB other" > "$TMP/other.pub"
  run sign --mode ssh --key "$TMP/other.pub" --apply
  [ "$status" -eq 0 ]
  [ "$(cfg user.signingkey)" = "$TMP/other.pub" ]
  run sign --mode ssh --key "$TMP/ghost.pub" --apply
  [ "$status" -ne 0 ]
}

@test "ssh with no resolvable key dies with a hint, no writes" {
  rm -f "$FAKE_HOME/.ssh/"*.pub
  run sign --mode ssh --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ssh-keygen"
  [ "$(cfg commit.gpgsign)" = "(unset)" ]
}

@test "gitsign apply sets x509 + program; absent binary refuses with no writes" {
  run env HOME="$FAKE_HOME" PATH="$GITSIGN_STUB:$PATH" bash "$SIGN" --target "$REPO" --mode gitsign --apply
  [ "$status" -eq 0 ]
  [ "$(cfg gpg.format)" = "x509" ]
  [ "$(cfg gpg.x509.program)" = "gitsign" ]
  git -C "$REPO" config --local --unset gpg.format
  git -C "$REPO" config --local --unset gpg.x509.program
  git -C "$REPO" config --local --unset commit.gpgsign
  git -C "$REPO" config --local --unset tag.gpgsign
  rm -f "$REPO/memory/.nyann/signing-setup.json"
  run bash -c 'env HOME="$1" PATH="/usr/bin:/bin" bash "$2" --target "$3" --mode gitsign --apply' _ "$FAKE_HOME" "$SIGN" "$REPO"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "gitsign is not installed"
  [ "$(cfg gpg.format)" = "(unset)" ]
}

@test "gpg apply sets openpgp + gpgsign (+ signingkey with --key)" {
  run sign --mode gpg --key ABCD1234 --apply
  [ "$status" -eq 0 ]
  [ "$(cfg gpg.format)" = "openpgp" ]
  [ "$(cfg user.signingkey)" = "ABCD1234" ]
}

@test "record carries original priors (null for previously-unset keys)" {
  git -C "$REPO" config --local gpg.format openpgp
  sign --mode ssh --apply >/dev/null 2>&1
  rec="$REPO/memory/.nyann/signing-setup.json"
  [ "$(jq -r '.mode' "$rec")" = "ssh" ]
  [ "$(jq -r '.entries[] | select(.key=="gpg.format") | .prior' "$rec")" = "openpgp" ]
  [ "$(jq -r '.entries[] | select(.key=="commit.gpgsign") | .prior' "$rec")" = "null" ]
}

@test "re-apply preserves the ORIGINAL priors (undo returns to pre-nyann state)" {
  git -C "$REPO" config --local gpg.format openpgp
  sign --mode ssh --apply >/dev/null 2>&1
  sign --mode ssh --apply >/dev/null 2>&1
  rec="$REPO/memory/.nyann/signing-setup.json"
  [ "$(jq -r '.entries[] | select(.key=="gpg.format") | .prior' "$rec")" = "openpgp" ]
  sign --undo >/dev/null 2>&1
  [ "$(cfg gpg.format)" = "openpgp" ]
  [ "$(cfg commit.gpgsign)" = "(unset)" ]
  [ "$(cfg user.signingkey)" = "(unset)" ]
  [ ! -f "$rec" ]
}

@test "undo restores previously-set values and unsets previously-unset ones" {
  git -C "$REPO" config --local commit.gpgsign false
  sign --mode ssh --apply >/dev/null 2>&1
  sign --undo >/dev/null 2>&1
  [ "$(cfg commit.gpgsign)" = "false" ]
  [ "$(cfg gpg.format)" = "(unset)" ]
  [ "$(cfg tag.gpgsign)" = "(unset)" ]
}

@test "undo with no record dies clearly" {
  run sign --undo
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "nothing to undo"
}

@test "global git config is never touched" {
  gcfg="$FAKE_HOME/.gitconfig"
  touch "$gcfg"
  before=$(cat "$gcfg")
  sign --mode ssh --apply >/dev/null 2>&1
  [ "$(cat "$gcfg")" = "$before" ]
}

@test "record validates against the SigningSetupRecord schema shape" {
  sign --mode ssh --apply >/dev/null 2>&1
  rec="$REPO/memory/.nyann/signing-setup.json"
  [ "$(jq -r 'keys - ["applied_at","entries","mode"] | length' "$rec")" = "0" ]
  [ "$(jq -r '.entries[0] | keys - ["key","new","prior"] | length' "$rec")" = "0" ]
}

# --- mode-aware signing audit (gh-protect local half) ------------------------
# The signing audit module only runs when gh is reachable (the no-gh path
# emits a static skeleton), so these tests stub gh with minimal responses.

make_gh_mock() {
  mkdir -p "$TMP/ghmock"
  cat > "$TMP/ghmock/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")   echo '{"nameWithOwner":"o/r"}'; exit 0 ;;
esac
echo '{}'
exit 0
SH
  chmod +x "$TMP/ghmock/gh"
}

audit_signing() { # stdout: full ProtectionAudit JSON
  make_gh_mock
  env HOME="$TMP" bash "$REPO_ROOT/bin/gh-integration.sh" --target "$REPO" \
    --profile signing-test --gh "$TMP/ghmock/gh" --check 2>/dev/null || true
}

# Install a user profile (by name) with signing requirements + mode.
install_profile() { # $1=mode
  mkdir -p "$TMP/.claude/nyann/profiles"
  jq --arg m "$1" '.name = "signing-test"
    | .github.require_signed_commits = true
    | .security = {commit_signing: {mode: $m}}' \
    "$REPO_ROOT/tests/fixtures/profiles/valid-minimal.json" \
    > "$TMP/.claude/nyann/profiles/signing-test.json"
}

@test "audit: gitsign keyless config raises no user.signingkey drift" {
  install_profile gitsign
  env HOME="$FAKE_HOME" PATH="$GITSIGN_STUB:$PATH" bash "$SIGN" --target "$REPO" --mode gitsign --apply >/dev/null 2>&1
  out=$(audit_signing)
  [ "$(echo "$out" | jq -r '.signing.local_config.mode')" = "gitsign" ]
  [ "$(echo "$out" | jq -r '[.signing.drift[] | select(.field == "user.signingkey")] | length')" = "0" ]
}

@test "audit: profile mode mismatch is warn-level drift" {
  install_profile ssh
  out=$(audit_signing)
  [ "$(echo "$out" | jq -r '.signing.local_config.mode')" = "gpg" ]
  [ "$(echo "$out" | jq -r '[.signing.drift[] | select(.field == "security.commit_signing.mode")] | length')" = "1" ]
  [ "$(echo "$out" | jq -r '.signing.drift[] | select(.field == "security.commit_signing.mode") | .severity')" = "warn" ]
}

@test "audit: matching declared mode raises no mode drift" {
  install_profile ssh
  env HOME="$FAKE_HOME" bash "$SIGN" --target "$REPO" --mode ssh --apply >/dev/null 2>&1
  out=$(audit_signing)
  [ "$(echo "$out" | jq -r '.signing.local_config.mode')" = "ssh" ]
  [ "$(echo "$out" | jq -r '[.signing.drift[] | select(.field == "security.commit_signing.mode")] | length')" = "0" ]
}
