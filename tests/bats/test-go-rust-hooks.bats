#!/usr/bin/env bats
# bin/install-hooks.sh --go / --rust phases + fallback-when-prereq-missing.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL="${REPO_ROOT}/bin/install-hooks.sh"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

seed() {
  cp -r "${REPO_ROOT}/tests/fixtures/$1/." "${TMP}/"
  ( cd "$TMP" && git init -q -b main )
}

@test "--go writes pre-commit config with go-fmt / go-vet / golangci-lint" {
  if ! command -v go >/dev/null 2>&1; then skip "go not installed on this host"; fi
  seed go-empty
  run bash "$INSTALL" --target "$TMP" --go --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$TMP/.pre-commit-config.yaml" ]
  grep -Fq 'pre-commit-golang' "$TMP/.pre-commit-config.yaml"
  grep -Fq 'golangci-lint'     "$TMP/.pre-commit-config.yaml"
  grep -Fq 'block-main'        "$TMP/.pre-commit-config.yaml"
}

@test "--rust writes pre-commit config with fmt + clippy --deny warnings" {
  if ! command -v cargo >/dev/null 2>&1; then skip "cargo not installed on this host"; fi
  seed rust-empty
  run bash "$INSTALL" --target "$TMP" --rust --no-install-hook
  [ "$status" -eq 0 ]
  [ -f "$TMP/.pre-commit-config.yaml" ]
  grep -Fq 'doublify/pre-commit-rust' "$TMP/.pre-commit-config.yaml"
  grep -Eq 'clippy' "$TMP/.pre-commit-config.yaml"
  grep -Eq 'deny' "$TMP/.pre-commit-config.yaml"
}

@test "--go emits skip record when go is absent" {
  # CI Ubuntu runners have `go` in /usr/bin, so /usr/bin:/bin still finds
  # it. Use a scratch dir with only jq symlinked — guarantees no go.
  seed go-empty
  empty_bin="$TMP/empty-bin"
  mkdir -p "$empty_bin"
  # Symlink every executable nyann's scripts touch except the one we're
  # specifically testing as "missing".
  for exe in jq git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum python3 bash; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$empty_bin/$exe" 2>/dev/null || true
  done
  run env -i HOME="$HOME" PATH="$empty_bin" bash "$INSTALL" --target "$TMP" --go --no-install-hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"skipped":"go-hooks"'
}

@test "--rust emits skip record when cargo is absent" {
  seed rust-empty
  empty_bin="$TMP/empty-bin"
  mkdir -p "$empty_bin"
  # Symlink every executable nyann's scripts touch except the one we're
  # specifically testing as "missing".
  for exe in jq git grep sed awk tr basename dirname cat mkdir cp mv rm ls find stat head tail wc shasum sha256sum python3 bash; do
    src=$(command -v "$exe" 2>/dev/null) || continue
    [[ -n "$src" ]] && ln -s "$src" "$empty_bin/$exe" 2>/dev/null || true
  done
  run env -i HOME="$HOME" PATH="$empty_bin" bash "$INSTALL" --target "$TMP" --rust --no-install-hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq '"skipped":"rust-hooks"'
}
