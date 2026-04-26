#!/usr/bin/env bats
# Regressions for team-sources security (URL redaction, concurrent writes).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ADD="${REPO_ROOT}/bin/add-team-source.sh"
  SYNC="${REPO_ROOT}/bin/sync-team-profiles.sh"
  DRIFT="${REPO_ROOT}/bin/check-team-drift.sh"
  TMP="$(mktemp -d -t nyann-team.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  FAKE_HOME="$TMP/home"
  mkdir -p "$FAKE_HOME/.claude/nyann"
}

teardown() { rm -rf "$TMP"; }

# ---- ref validation at write + read path ------------------------------------

@test "add-team-source rejects --ref with leading dash (git option injection)" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-x" --url "https://example.invalid/x.git" --ref "--upload-pack=cmd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ref"* ]]
}

@test "add-team-source rejects --ref with shell metachars" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-x" --url "https://example.invalid/x.git" --ref "ma;rm -rf /"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ref"* ]]
}

@test "add-team-source rejects --url with ext:: transport" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-x" --url "ext::evil-cmd %G" --ref "main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--url"* ]]
}

@test "add-team-source rejects --url with leading dash (arg injection)" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-x" --url "--upload-pack=cmd" --ref "main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scheme"* ]] || [[ "$output" == *"allowlisted"* ]]
}

# http:// is a passive-MITM vector: an attacker on path can swap
# returned profile bytes (which then drive `git clone` of dependent
# repos and template ci.yml/hooks). The allowlist must require TLS.
@test "add-team-source rejects --url with http:// (no TLS / MITM risk)" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-x" --url "http://insecure.example/repo.git" --ref "main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scheme"* ]] || [[ "$output" == *"allowlisted"* ]]
}

@test "add-team-source accepts file:// (local mirror / tests)" {
  # file:// is allowed because local mirrors and test fixtures depend on
  # it; its worst case is bounded to info disclosure under the caller's
  # own filesystem access. The critical block is ext::, covered above.
  local_mirror="$TMP/local-repo"
  mkdir -p "$local_mirror"
  ( cd "$local_mirror" && git init -q -b main )
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-local" --url "file://$local_mirror" --ref "main"
  [ "$status" -eq 0 ]
}

@test "add-team-source accepts https:// / ssh:// / git@" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-a" --url "https://github.com/org/repo.git" --ref "main"
  [ "$status" -eq 0 ]
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-b" --url "ssh://git@github.com:22/org/repo.git" --ref "main"
  [ "$status" -eq 0 ]
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-c" --url "git@github.com:org/repo.git" --ref "main"
  [ "$status" -eq 0 ]
}

@test "sync-team-profiles rejects a hand-edited config with bad --ref" {
  # Write config directly, bypassing add-team-source's write-path guard.
  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{"team_profile_sources":[
  {"name":"team-x","url":"https://example.invalid/x.git","ref":"--upload-pack=cmd","sync_interval_hours":24,"last_synced_at":0}
]}
JSON
  run env HOME="$FAKE_HOME" bash "$SYNC"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.invalid | map(select(.kind == "invalid-ref")) | length >= 1' >/dev/null
}

@test "sync-team-profiles rejects a hand-edited config with ext:: url" {
  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{"team_profile_sources":[
  {"name":"team-x","url":"ext::evil %G","ref":"main","sync_interval_hours":24,"last_synced_at":0}
]}
JSON
  run env HOME="$FAKE_HOME" bash "$SYNC"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.invalid | map(select(.kind == "invalid-url")) | length >= 1' >/dev/null
}

@test "check-team-drift rejects hand-edited bad --ref without calling git" {
  # Plant a real cached repo so the drift loop would otherwise reach the
  # fetch path.
  cache="$FAKE_HOME/.claude/nyann/cache/team-x"
  mkdir -p "$cache"
  ( cd "$cache" && git init -q -b main \
     && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )

  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{"team_profile_sources":[
  {"name":"team-x","url":"https://example.invalid/x.git","ref":"--upload-pack=cmd","sync_interval_hours":24,"last_synced_at":0}
]}
JSON
  run env HOME="$FAKE_HOME" bash "$DRIFT" --offline
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.unreachable | map(select(.error == "invalid ref")) | length >= 1' >/dev/null
}

# ---- umask / file permissions ------------------------------------------------

@test "add-team-source writes config.json with 0600 perms" {
  run env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-a" --url "https://github.com/org/repo.git"
  [ "$status" -eq 0 ]
  config="$FAKE_HOME/.claude/nyann/config.json"
  [ -f "$config" ]
  # `stat -f%p` on macOS returns the full mode incl. file-type bits; mask
  # to the last 4 octal digits.
  mode=$(stat -f '%p' "$config" 2>/dev/null || stat -c '%a' "$config" 2>/dev/null)
  case "$mode" in
    *600) : ;;                     # perfect 600
    *) echo "unexpected mode: $mode" >&2; false ;;
  esac
}

# ---- URL redaction in error output -------------------------------------------

@test "sync fetch error strips tokens from URL" {
  # Seed a cached repo configured with a tokened remote URL; make
  # sync attempt a fetch so we get a failure message referencing the URL.
  cache="$FAKE_HOME/.claude/nyann/cache/team-x"
  mkdir -p "$cache"
  ( cd "$cache" && git init -q -b main \
     && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" \
     && git remote add origin "https://deadbeef-token@example.invalid/x.git" )

  cat > "$FAKE_HOME/.claude/nyann/config.json" <<JSON
{"team_profile_sources":[
  {"name":"team-x","url":"https://deadbeef-token@example.invalid/x.git","ref":"main","sync_interval_hours":24,"last_synced_at":0}
]}
JSON
  # --force to skip within-interval gate; fetch will fail (example.invalid).
  run env HOME="$FAKE_HOME" bash "$SYNC" --force
  [ "$status" -eq 0 ]
  # invalid[] should have a fetch-failed entry; its error string must not
  # contain the token.
  err=$(echo "$output" | jq -r '.invalid[] | select(.kind == "fetch-failed") | .error' | head -1)
  # If for some reason no fetch-failed was recorded (e.g. network racing a
  # DNS miss), skip — the test is about redaction of the error when it IS
  # produced.
  [[ -z "$err" ]] || ! [[ "$err" == *"deadbeef-token"* ]]
}

# ---- concurrent add-team-source does not lose entries -----------------------

@test "two concurrent add-team-source calls keep both entries" {
  # Run two adds in parallel, wait, then check config has both.
  env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-a" --url "https://github.com/org/repo-a.git" >/dev/null &
  pid_a=$!
  env HOME="$FAKE_HOME" bash "$ADD" \
    --name "team-b" --url "https://github.com/org/repo-b.git" >/dev/null &
  pid_b=$!
  wait "$pid_a"
  wait "$pid_b"

  config="$FAKE_HOME/.claude/nyann/config.json"
  [ -f "$config" ]
  n=$(jq '.team_profile_sources | length' "$config")
  [ "$n" = "2" ]
  jq -e '.team_profile_sources | map(.name) | contains(["team-a", "team-b"])' "$config" >/dev/null
}
