#!/usr/bin/env bats
# CI sentinel — focuses on the non-network parts: notification queue
# handling, --stop semantics, schema validation. Real gh polling is mocked.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-sentinel.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  STATE_DIR="$TMP/state"
  NOTIF_DIR="$TMP/notifs"
  mkdir -p "$STATE_DIR" "$NOTIF_DIR"
}

teardown() { rm -rf "$TMP"; }

@test "soft-skips with helpful message when gh is missing" {
  # Run with PATH stripped of gh.
  out=$( PATH=/usr/bin:/bin bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo o/r --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR" 2>&1 || true )
  echo "$out" | grep -q "gh CLI not installed"
}

@test "--stop is a noop when no pid file exists" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo o/r --stop --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -eq 0 ]
}

@test "--repo is required" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
}

@test "--pr rejects a non-integer value" {
  run bash "$REPO_ROOT/bin/ci-sentinel.sh" --repo o/r --pr abc --state-dir "$STATE_DIR" --notif-dir "$NOTIF_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must be a positive integer"
}

@test "--pr accepts a positive integer (soft-skips when gh missing)" {
  run bash -c "PATH=/usr/bin:/bin bash '$REPO_ROOT/bin/ci-sentinel.sh' --repo o/r --pr 42 --state-dir '$STATE_DIR' --notif-dir '$NOTIF_DIR'"
  [ "$status" -eq 0 ]
}

@test "read-notifications returns [] when queue file missing" {
  out=$(bash "$REPO_ROOT/bin/read-notifications.sh" --repo o/r --notif-dir "$NOTIF_DIR")
  echo "$out" | jq -e '. == []'
}

@test "read-notifications returns queued entries then truncates" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  notif="$NOTIF_DIR/${hash}.jsonl"
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"warning", message:"PR #42: CI failed", context:{pr:42}}' > "$notif"
  jq -n '{timestamp:"2026-05-28T00:00:05Z", source:"sentinel", severity:"info",    message:"PR #43: approved",  context:{pr:43}}' >> "$notif"
  out=$(bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$repo" --notif-dir "$NOTIF_DIR")
  count=$(echo "$out" | jq 'length')
  [ "$count" -eq 2 ]
  # File truncated.
  [ ! -s "$notif" ]
}

@test "read-notifications --peek leaves the file intact" {
  repo="o/r"
  hash=$(printf '%s' "$repo" | (md5sum 2>/dev/null || md5 -q 2>/dev/null) | cut -c1-12)
  notif="$NOTIF_DIR/${hash}.jsonl"
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"info", message:"x", context:{}}' > "$notif"
  before=$(wc -c < "$notif")
  bash "$REPO_ROOT/bin/read-notifications.sh" --repo "$repo" --notif-dir "$NOTIF_DIR" --peek > /dev/null
  after=$(wc -c < "$notif")
  [ "$before" -eq "$after" ]
}

@test "Notification JSON validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{timestamp:"2026-05-28T00:00:00Z", source:"sentinel", severity:"warning", message:"x", context:{pr:1}}' > "$TMP/n.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/notification.schema.json" "$TMP/n.json"
}

@test "SentinelState JSON validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  jq -n '{repo:"o/r", pr_number:42, base_branch:"main", head_branch:"feature/x", last_poll_at:"2026-05-28T00:00:00Z", checks_status:"pending", review_status:"no-reviews", merged:false}' > "$TMP/s.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/sentinel-state.schema.json" "$TMP/s.json"
}
