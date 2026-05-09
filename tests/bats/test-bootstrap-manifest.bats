#!/usr/bin/env bats
# bin/bootstrap.sh — produces a BootRecord manifest under
# memory/.nyann/bootstraps/<ts>/manifest.json that captures pre-state
# bytes for every file it touched. Consumed by bin/undo-bootstrap.sh.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  TMP=$(mktemp -d)
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  cat > "$TMP/profile.json" <<'JSON'
{"name":"default","version":1,"stack":{"primary_language":"unknown"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"conventions":{"commit_format":"conventional","commit_scopes":[]},"extras":{"editorconfig":false,"github_templates":false,"gitignore":false},"documentation":{"claude_md_mode":"off","doc_targets":[],"scaffold_set":[]},"ci":{"enabled":false}}
JSON
  cat > "$TMP/docplan.json" <<'JSON'
{"target_storage": "local", "claude_md_mode": "off", "targets": [], "registry_version": "v1"}
JSON
  cat > "$TMP/stack.json" <<'JSON'
{"primary_language": "unknown", "secondary_languages": [], "frameworks": [], "package_managers": [], "is_monorepo": false, "claude_md_hints": [], "archetype": "unknown"}
JSON
}

teardown() { rm -rf "$TMP"; }

plan_sha() { bash "$PREVIEW" --plan "$1" --emit-sha256 2>/dev/null; }

bootstrap_with_plan() {
  local plan="$1"
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$plan" \
    --plan-sha256 "$(plan_sha "$plan")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
}

@test "bootstrap writes a BootRecord manifest under memory/.nyann/bootstraps/" {
  echo "node_modules" > "$REPO/.gitignore"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  [ -n "$manifest" ]
  [ -f "$manifest" ]
}

@test "manifest validates against schemas/boot-record.schema.json" {
  command -v uvx >/dev/null 2>&1 || skip "uvx not available"
  echo "node_modules" > "$REPO/.gitignore"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  run uvx --quiet check-jsonschema --schemafile "${REPO_ROOT}/schemas/boot-record.schema.json" "$manifest"
  [ "$status" -eq 0 ]
}

@test "manifest source is 'bootstrap' by default and 'retrofit' with --source retrofit" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  source="$(jq -r '.source' "$manifest")"
  [ "$source" = "bootstrap" ]

  # Wipe and re-run with --source retrofit
  rm -rf "$REPO/memory"
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --source retrofit
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  source="$(jq -r '.source' "$manifest")"
  [ "$source" = "retrofit" ]
}

@test "manifest write actions carry pre_state_blob and post_state_sha256 for merged files" {
  echo "node_modules" > "$REPO/.gitignore"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  # The .gitignore write should have pre_existed=true, a blob, both shas.
  entry="$(jq -c '.actions[] | select(.kind=="write" and .path==".gitignore")' "$manifest")"
  [ "$(jq -r '.pre_existed' <<<"$entry")" = "true" ]
  [ "$(jq -r '.pre_state_blob' <<<"$entry")" != "null" ]
  [ "$(jq -r '.pre_state_sha256' <<<"$entry")" != "null" ]
  [ "$(jq -r '.post_state_sha256' <<<"$entry")" != "null" ]
}

@test "bootstrap with --source rejects an unknown source value" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --source nonsense
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "must be bootstrap|retrofit"
}

@test "newly-created hook files are recorded as create actions" {
  # Reviewer-flagged scenario: br_snapshot_dir only snapshots files
  # that exist before bootstrap, but install-hooks materialises new
  # ones (e.g., .git/hooks/commit-msg) on a fresh repo. The post-dir
  # diff in br_finalize_writes should pick them up.
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  # install-hooks --core writes a commit-msg validator on every bootstrap.
  # That file didn't exist pre-bootstrap (only .git/hooks/*.sample did).
  jq -e '[.actions[] | select(.kind=="write" and .path==".git/hooks/commit-msg" and .pre_existed==false)] | length >= 1' "$manifest" >/dev/null
}

@test "br_snapshot refuses path-traversal in plan.writes[]" {
  # Reviewer-flagged P1: a malicious plan that attempts to escape the
  # target via .. would otherwise have its bytes copied into pre-state/.
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":"../../etc/passwd","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  # The script rejects the plan during the writes[] loop. What matters
  # is that the manifest's tracked.tsv (and any pre-state blobs)
  # contain NO entry for the escaping path. We assert by scanning the
  # boot record's manifest if it was produced.
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json 2>/dev/null | head -1)"
  if [ -n "$manifest" ] && [ -f "$manifest" ]; then
    # No action should reference the escaping path.
    matches="$(jq '[.actions[] | select(.path | tostring | test("\\.\\."))] | length' "$manifest" 2>/dev/null || echo 0)"
    [ "$matches" = "0" ]
  fi
  # And bootstrap should have surfaced the rejection on stderr.
  echo "$output" | grep -Fq "rejected" || echo "$output" | grep -Fq "refusing"
}

@test "br_snapshot records symlinks as irreversible (preserving caller category)" {
  # Reviewer-flagged: there's a symlink branch in br_snapshot but no
  # test for it. Create a symlink the snapshot will encounter, run
  # bootstrap, then check the manifest.
  ln -s /tmp "$REPO/.gitignore"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  if [ -f "$manifest" ]; then
    # The action emitted for .gitignore should carry reversible=false
    # and the category from the caller (gitignore), NOT the legacy
    # hardcoded "hooks".
    jq -e '[.actions[] | select(.kind=="write" and .path==".gitignore")] | .[0] | (.reversible == false and .category == "gitignore")' "$manifest" >/dev/null
  fi
}

@test "br_snapshot refuses paths with embedded newline or US separator" {
  # Reviewer-flagged P2: control characters would corrupt tracked.tsv
  # and produce schema-invalid manifest entries.
  weird_path=$(printf 'odd\nname.txt')
  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":"$weird_path","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json 2>/dev/null | head -1)"
  if [ -n "$manifest" ] && [ -f "$manifest" ]; then
    # No action should reference a path containing a newline.
    matches="$(jq '[.actions[] | select(.path | tostring | test("\n"))] | length' "$manifest" 2>/dev/null || echo 0)"
    [ "$matches" = "0" ]
  fi
}

@test "profile_sha256 is canonicalised (jq -Sc), not raw-file SHA" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  recorded="$(jq -r '.profile_sha256' "$manifest")"
  expected="$(jq -Sc . "$TMP/profile.json" | tr -d '\n' | shasum -a 256 | awk '{print $1}')"
  [ "$recorded" = "$expected" ]
}

@test "summary JSON includes boot_record path" {
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  run bootstrap_with_plan "$TMP/plan.json"
  [ "$status" -eq 0 ]
  # bootstrap emits a JSON summary; pull it from stdout.
  # Lines that aren't JSON come from stderr or are interleaved logs;
  # extract the concluding object.
  summary="$(echo "$output" | sed -n '/^{$/,/^}$/p')"
  [ -n "$summary" ]
  br="$(jq -r '.boot_record' <<<"$summary")"
  [ "$br" != "null" ]
  [ -f "$br" ]
}
