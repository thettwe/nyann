#!/usr/bin/env bats
# bin/preview.sh --json — machine-readable PreviewResult output.
#
# Covers:
#   - PreviewResult shape on a minimal valid plan
#   - schema validates against schemas/preview-result.schema.json
#   - --json + --emit-sha256 rejected with rc 2
#   - legacy mode (no --json) still emits bare ActionPlan on stdout
#   - --skip filters before the SHA is computed AND skips_applied
#     reports only paths that actually matched a write
#   - --decision no in --json mode emits a structured declined payload
#     to stdout and exits 1

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-preview-json.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"

  # Minimal valid plan with mixed actions so the histogram is non-trivial.
  cat > "$TMP/plan.json" <<'JSON'
{
  "writes": [
    { "path": ".gitignore", "action": "merge",  "bytes": 234 },
    { "path": "CLAUDE.md",  "action": "create", "bytes": 1500 },
    { "path": "docs/architecture.md", "action": "create", "bytes": 800 }
  ],
  "commands": [{ "cmd": "git init", "cwd": "." }],
  "remote": []
}
JSON
}

teardown() { rm -rf "$TMP"; }

run_preview() {
  bash "${REPO_ROOT}/bin/preview.sh" "$@"
}

# --- shape -----------------------------------------------------------------

@test "preview --json emits a PreviewResult with required top-level keys" {
  run run_preview --plan "$TMP/plan.json" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    has("plan") and has("summary") and has("plan_sha256") and has("skips_applied")
  ' >/dev/null
}

@test "preview --json carries the post-skip plan unchanged" {
  run run_preview --plan "$TMP/plan.json" --json
  [ "$status" -eq 0 ]
  # Round-trip the embedded plan through jq -Sc and compare against the
  # source plan canonicalised the same way; the contents must match.
  echo "$output" | jq -c '.plan' > "$TMP/got.json"
  jq -Sc . "$TMP/plan.json" > "$TMP/want.json"
  jq -Sc . "$TMP/got.json"  > "$TMP/got.canon"
  diff -u "$TMP/want.json" "$TMP/got.canon"
}

@test "preview --json summary reflects write_count, command_count, remote_count" {
  run run_preview --plan "$TMP/plan.json" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.summary.write_count')"   = "3" ]
  [ "$(echo "$output" | jq '.summary.command_count')" = "1" ]
  [ "$(echo "$output" | jq '.summary.remote_count')"  = "0" ]
}

@test "preview --json action histogram counts each action" {
  run run_preview --plan "$TMP/plan.json" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.summary.actions.create')" = "2" ]
  [ "$(echo "$output" | jq '.summary.actions.merge')"  = "1" ]
}

@test "preview --json total_bytes sums writes[].bytes" {
  run run_preview --plan "$TMP/plan.json" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.summary.total_bytes')" = "2534" ]
}

@test "preview --json plan_sha256 is 64 lowercase hex characters" {
  run run_preview --plan "$TMP/plan.json" --json
  [ "$status" -eq 0 ]
  sha=$(echo "$output" | jq -r '.plan_sha256')
  # On systems without shasum/sha256sum the SHA is "" and the integrity
  # binding is disabled — accept that explicitly so the test passes on
  # such hosts. Otherwise enforce the hex shape.
  if [[ -n "$sha" ]]; then
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
  fi
}

@test "preview --json plan_sha256 matches preview --emit-sha256" {
  # bats `run` captures stdout+stderr combined, but --emit-sha256 still
  # writes the human stderr render. Drop stderr explicitly so the
  # captured value is the bare hex.
  hex_only=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --emit-sha256 2>/dev/null)
  json_sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --json | jq -r '.plan_sha256')
  [ "$hex_only" = "$json_sha" ]
}

# --- skip semantics --------------------------------------------------------

@test "preview --json --skip removes write AND records the skip" {
  run run_preview --plan "$TMP/plan.json" --skip ".gitignore" --json
  [ "$status" -eq 0 ]
  # Plan no longer contains .gitignore.
  [ "$(echo "$output" | jq '[.plan.writes[].path] | index(".gitignore")')" = "null" ]
  [ "$(echo "$output" | jq '.summary.write_count')" = "2" ]
  # skips_applied carries the matched path.
  [ "$(echo "$output" | jq -r '.skips_applied[0]')" = ".gitignore" ]
  [ "$(echo "$output" | jq '.skips_applied | length')" = "1" ]
}

@test "preview --json --skip with non-matching path drops it from skips_applied" {
  run run_preview --plan "$TMP/plan.json" --skip "no-such-file.txt" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.skips_applied | length')" = "0" ]
  # Plan unchanged.
  [ "$(echo "$output" | jq '.summary.write_count')" = "3" ]
}

@test "preview --json SHA is computed over the post-skip plan" {
  # Same plan, different --skip → different SHA expected.
  run run_preview --plan "$TMP/plan.json" --json
  sha_full=$(echo "$output" | jq -r '.plan_sha256')
  run run_preview --plan "$TMP/plan.json" --skip "CLAUDE.md" --json
  sha_filt=$(echo "$output" | jq -r '.plan_sha256')
  if [[ -n "$sha_full" && -n "$sha_filt" ]]; then
    [ "$sha_full" != "$sha_filt" ]
  fi
}

# --- flag conflicts --------------------------------------------------------

@test "preview --json + --emit-sha256 rejected" {
  run run_preview --plan "$TMP/plan.json" --json --emit-sha256
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "mutually exclusive"
}

# --- decision = no --------------------------------------------------------

@test "preview --json --decision no emits a structured declined payload" {
  run run_preview --plan "$TMP/plan.json" --json --decision no
  [ "$status" -eq 1 ]
  # Output is a single JSON object on stdout (not stderr text).
  echo "$output" | jq -e '.declined == true' >/dev/null
}

# --- backwards compatibility ----------------------------------------------

@test "preview without --json still emits bare ActionPlan on stdout" {
  # Legacy mode renders to stderr too; drop it so the assertion sees
  # only the bare ActionPlan that bootstrap.sh consumes.
  out=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" 2>/dev/null)
  echo "$out" | jq -e 'has("writes") and has("commands") and has("remote") and (has("plan") | not)' >/dev/null
}

# --- schema -----------------------------------------------------------------

@test "preview --json output validates against schemas/preview-result.schema.json" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator (install check-jsonschema or uvx)"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  run_preview --plan "$TMP/plan.json" --json > "$TMP/out.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/preview-result.schema.json" "$TMP/out.json"
}
