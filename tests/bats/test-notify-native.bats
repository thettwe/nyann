#!/usr/bin/env bats
# Native OS notification channel (bin/notify-channels/native.sh). osascript /
# notify-send are PATH stubs capturing argv. Covers the one-toast digest,
# tool pick by availability, headless soft-skips, and — the channel's whole
# job — AppleScript/argv injection hardening.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-native.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  CH="$REPO_ROOT/bin/notify-channels/native.sh"

  OSA_LOG="$TMP/osa.log"
  NS_LOG="$TMP/ns.log"
  export OSA_LOG NS_LOG
  export OSA_RC=0

  # base: a minimal PATH containing just what native.sh + _lib.sh need —
  # and NO osascript/notify-send, so availability is controlled entirely by
  # which stub dir we prepend. An allowlist beats mirroring the real PATH:
  # ubuntu runners carry thousands of entries including dangling symlinks
  # (where `-e` is false but the link name exists, so `ln -s` fails and
  # aborts bats setup), and the full mirror cost ~19s per test.
  BASE="$TMP/base"
  mkdir -p "$BASE"
  for t in bash jq cat sed grep dirname basename head tr hostname; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -s "$p" "$BASE/$t" 2>/dev/null || true
  done

  OSA="$TMP/osa"
  mkdir -p "$OSA"
  cat > "$OSA/osascript" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OSA_LOG"
exit "${OSA_RC:-0}"
SH
  chmod +x "$OSA/osascript"

  NS="$TMP/ns"
  mkdir -p "$NS"
  cat > "$NS/notify-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$NS_LOG"
exit 0
SH
  chmod +x "$NS/notify-send"

  BATCH='[{"severity":"critical","message":"CI failed on main","context":{"pr":4,"repo":"o/r"}}]'
}

teardown() { rm -rf "$TMP"; }

@test "single notification renders one toast via osascript" {
  run bash -c 'printf "%s" "$1" | PATH="$2:$3" bash "$4"' _ "$BATCH" "$OSA" "$BASE" "$CH"
  [ "$status" -eq 0 ]
  grep -q 'display notification "\[critical\] \[o/r\] CI failed on main" with title "nyann"' "$OSA_LOG"
}

@test "a batch collapses to one toast with a (+N more) suffix" {
  batch='[{"severity":"critical","message":"first"},{"severity":"info","message":"second"},{"severity":"info","message":"third"}]'
  run bash -c 'printf "%s" "$1" | PATH="$2:$3" bash "$4"' _ "$batch" "$OSA" "$BASE" "$CH"
  [ "$status" -eq 0 ]
  grep -q '(+2 more)' "$OSA_LOG"
  [ "$(grep -c 'display notification' "$OSA_LOG")" -eq 1 ]
}

@test "AppleScript injection: quotes, backslashes, \$() and backticks stay inert" {
  evil='[{"severity":"critical","message":"x\" & (do shell script \"touch /tmp/pwn\") & \"$(evil) `bt` back\\\\slash"}]'
  run bash -c 'printf "%s" "$1" | PATH="$2:$3" bash "$4"' _ "$evil" "$OSA" "$BASE" "$CH"
  [ "$status" -eq 0 ]
  # Every double quote from the payload arrives ESCAPED (\") — the
  # AppleScript string can't be broken out of.
  ! grep -q 'x" &' "$OSA_LOG"
  grep -q 'x\\"' "$OSA_LOG"
  # Shell metacharacters travel as literal text.
  grep -q '\$(evil)' "$OSA_LOG"
  grep -q '`bt`' "$OSA_LOG"
}

@test "control characters are stripped and the text is capped at 180 chars" {
  long=$(printf 'A%.0s' $(seq 1 400))
  batch=$(jq -n --arg m "badbell $long" '[{"severity":"info","message":$m}]')
  run bash -c 'printf "%s" "$1" | PATH="$2:$3" bash "$4"' _ "$batch" "$OSA" "$BASE" "$CH"
  [ "$status" -eq 0 ]
  ! grep -q "$(printf '\a')" "$OSA_LOG"
  line=$(grep 'display notification' "$OSA_LOG")
  [ "${#line}" -lt 260 ]
}

@test "no osascript → notify-send path with a GUI session" {
  run bash -c 'printf "%s" "$1" | DISPLAY=:0 PATH="$2:$3" bash "$4"' _ "$BATCH" "$NS" "$BASE" "$CH"
  [ "$status" -eq 0 ]
  grep -q '^nyann$' "$NS_LOG"
  grep -q '\[critical\]' "$NS_LOG"
}

@test "notify-send without a GUI session soft-skips with 75" {
  run bash -c 'printf "%s" "$1" | env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS PATH="$2:$3" bash "$4"' _ "$BATCH" "$NS" "$BASE" "$CH"
  [ "$status" -eq 75 ]
  echo "$output" | grep -q "no GUI session"
}

@test "neither tool available soft-skips with 75" {
  run bash -c 'printf "%s" "$1" | PATH="$2" bash "$3"' _ "$BATCH" "$BASE" "$CH"
  [ "$status" -eq 75 ]
  echo "$output" | grep -q "neither osascript nor notify-send"
}

@test "a failing osascript returns its status (batch retried, not marked)" {
  run bash -c 'printf "%s" "$1" | OSA_RC=3 PATH="$2:$3" bash "$4"' _ "$BATCH" "$OSA" "$BASE" "$CH"
  [ "$status" -eq 3 ]
}

@test "empty batch is a no-op success" {
  run bash -c 'printf "[]" | PATH="$2:$3" bash "$4"' _ "" "$OSA" "$BASE" "$CH"
  [ "$status" -eq 0 ]
  [ ! -f "$OSA_LOG" ]
}
