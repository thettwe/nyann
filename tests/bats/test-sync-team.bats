#!/usr/bin/env bats
# bin/sync-team-profiles.sh + bin/add-team-source.sh + team drift. Uses a
# local file:// source so tests never hit the network.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ADD="${REPO_ROOT}/bin/add-team-source.sh"
  SYNC="${REPO_ROOT}/bin/sync-team-profiles.sh"
  DRIFT="${REPO_ROOT}/bin/check-team-drift.sh"
  LOAD="${REPO_ROOT}/bin/load-profile.sh"
  TMP="$(mktemp -d)"
  UR="$TMP/ur"
  SRC="$TMP/src"

  mkdir -p "$SRC/profiles"
  jq '.name = "team-x" | .description = "v1"' "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$SRC/profiles/team-x.json"
  ( cd "$SRC" && git init -q -b main && git -c user.email=t@t -c user.name=t add . && git -c user.email=t@t -c user.name=t commit -q -m "initial" )
}

teardown() { rm -rf "$TMP"; }

@test "add-team-source writes valid config (schema)" {
  run bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC"
  [ "$status" -eq 0 ]
  [ -f "$UR/config.json" ]
  if command -v uvx >/dev/null 2>&1; then
    run uvx --quiet check-jsonschema --schemafile "${REPO_ROOT}/schemas/config.schema.json" "$UR/config.json"
    [ "$status" -eq 0 ]
  fi
}

@test "duplicate add-team-source → upsert in place" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" --interval 12 >/dev/null 2>&1
  [ "$(jq '.team_profile_sources | length' "$UR/config.json")" -eq 1 ]
  [ "$(jq -r '.team_profile_sources[0].sync_interval_hours' "$UR/config.json")" = "12" ]
}

@test "sync first run clones; second within interval skips; --force re-syncs" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  run bash "$SYNC" --user-root "$UR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.synced | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.registered | length')" -eq 1 ]

  # Second run: within the default 24h interval → skipped.
  run bash "$SYNC" --user-root "$UR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.synced | length')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.skipped[0].reason')" = "within-interval" ]

  # --force → syncs again.
  run bash "$SYNC" --user-root "$UR" --force
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.synced | length')" -eq 1 ]
}

@test "load-profile resolves team-namespaced name" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  bash "$SYNC" --user-root "$UR" >/dev/null 2>&1
  # bats `run` captures stderr too; pipe stderr to /dev/null so the
  # loader's log lines don't pollute jq's input.
  out=$(bash "$LOAD" ours/team-x --user-root "$UR" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.description')" = "v1" ]
}

@test "user profile shadows team on bare name" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  bash "$SYNC" --user-root "$UR" >/dev/null 2>&1
  mkdir -p "$UR/profiles"
  jq '.description = "USER SHADOW" | .name = "team-x"' "${REPO_ROOT}/profiles/nextjs-prototype.json" > "$UR/profiles/team-x.json"
  out=$(bash "$LOAD" team-x --user-root "$UR" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.description')" = "USER SHADOW" ]
}

@test "team drift detector: up-to-date cache" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  bash "$SYNC" --user-root "$UR" >/dev/null 2>&1
  run bash "$DRIFT" --user-root "$UR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.drift | length')" -eq 0 ]
  [ "$(echo "$output" | jq '.up_to_date | length')" -eq 1 ]
}

@test "team drift detector: remote mutated → drift entry" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  bash "$SYNC" --user-root "$UR" >/dev/null 2>&1
  jq '.description = "v2"' "$SRC/profiles/team-x.json" > "$SRC/profiles/team-x.json.new"
  mv "$SRC/profiles/team-x.json.new" "$SRC/profiles/team-x.json"
  ( cd "$SRC" && git -c user.email=t@t -c user.name=t add . && git -c user.email=t@t -c user.name=t commit -q -m "v2" )
  run bash "$DRIFT" --user-root "$UR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.drift[0].kind')" = "remote-updated" ]
}

@test "load-profile rejects traversal in namespaced name (src component)" {
  # Regression: $name was split on / into src/pname and used to build a
  # filesystem path without re-validation. ../etc/passwd/x would escape
  # the cache dir.
  run bash "$LOAD" "../../etc/passwd/x" --user-root "$UR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid profile name"
}

@test "load-profile rejects traversal in namespaced name (pname component)" {
  run bash "$LOAD" "ours/../evil" --user-root "$UR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid profile name"
}

@test "load-profile rejects bare name with path separator or dots" {
  run bash "$LOAD" "../evil" --user-root "$UR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid profile name"

  run bash "$LOAD" "a/b/c" --user-root "$UR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid profile name"
}

@test "team drift detector: --offline reports cached hashes only" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1
  bash "$SYNC" --user-root "$UR" >/dev/null 2>&1
  run bash "$DRIFT" --user-root "$UR" --offline
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.up_to_date | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.drift | length')" -eq 0 ]
}

# If `jq` (or `mv`, `chmod`) fails between `nyann::lock` and
# `nyann::unlock`, `set -e` kills the script with the lockdir held.
# The EXIT trap must unwind the held lock so a follow-up sync proceeds
# immediately instead of waiting the full 10s lock timeout.
@test "mid-update failure doesn't leak the lockdir" {
  bash "$ADD" --user-root "$UR" --name ours --url "file://$SRC" >/dev/null 2>&1

  # Install a `jq` shim on PATH that fails only when it sees the
  # critical-section update filter (the one that writes
  # `last_synced_at`). Every other jq invocation (outer config parse,
  # argument extraction, etc.) delegates to the real jq. This
  # guarantees the lock IS acquired before the failure, which is the
  # only interesting case for the EXIT-trap behaviour.
  REAL_JQ="$(command -v jq)"
  SHIM_DIR="$TMP/shim"
  mkdir -p "$SHIM_DIR"
  # Match only the critical-section assignment filter — the read-side
  # `.last_synced_at // 0` at the top of the sync loop must still
  # succeed so we reach the actual lock acquisition.
  cat > "$SHIM_DIR/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == *".team_profile_sources ="* ]]; then
    echo "simulated jq failure in critical section" >&2
    exit 1
  fi
done
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$SHIM_DIR/jq"

  config="$UR/config.json"
  run env PATH="$SHIM_DIR:$PATH" bash "$SYNC" --user-root "$UR"
  # Script exits non-zero — the simulated jq failure inside the
  # critical section triggers `set -e`.
  [ "$status" -ne 0 ]

  # The real assertion: lockdir must be gone post-script-exit. Prior
  # behaviour left `$config.lockdir` behind; the new EXIT trap clears
  # it regardless of where we died.
  [ ! -e "$config.lockdir" ]
}
