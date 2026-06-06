#!/usr/bin/env bats
# bin/undo-bootstrap.sh — happy paths + refusal modes.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOTSTRAP="${REPO_ROOT}/bin/bootstrap.sh"
  PREVIEW="${REPO_ROOT}/bin/preview.sh"
  UNDO="${REPO_ROOT}/bin/undo-bootstrap.sh"
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

bootstrap_with_gitignore_merge() {
  echo "node_modules" > "$REPO/.gitignore"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1
}

@test "happy path: undo restores the pre-bootstrap .gitignore" {
  bootstrap_with_gitignore_merge
  pre="node_modules"
  run bash "$UNDO" --target "$REPO" --yes
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "undone"' >/dev/null
  echo "$output" | jq -e '.restored | length == 1' >/dev/null
  [ "$(cat "$REPO/.gitignore")" = "$pre" ]
}

@test "manifest dir is removed after a clean undo" {
  bootstrap_with_gitignore_merge
  bash "$UNDO" --target "$REPO" --yes >/dev/null
  count="$(find "$REPO/memory/.nyann/bootstraps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" = "0" ]
}

@test "--keep-record preserves the manifest dir after undo" {
  bootstrap_with_gitignore_merge
  bash "$UNDO" --target "$REPO" --yes --keep-record >/dev/null
  count="$(find "$REPO/memory/.nyann/bootstraps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" = "1" ]
}

@test "post-bootstrap edit is skipped without --force" {
  bootstrap_with_gitignore_merge
  echo "user-edit" >> "$REPO/.gitignore"
  run bash "$UNDO" --target "$REPO" --yes
  [ "$status" -eq 0 ]
  # Skip surfaces with reason mentioning the override flag.
  echo "$output" | jq -e '[.skipped[] | select(.kind=="write" and (.reason | test("--force")))] | length >= 1' >/dev/null
  # The user's edit is preserved.
  grep -Fq "user-edit" "$REPO/.gitignore"
}

@test "post-bootstrap edit is overwritten with --force" {
  bootstrap_with_gitignore_merge
  echo "user-edit" >> "$REPO/.gitignore"
  run bash "$UNDO" --target "$REPO" --yes --force
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.restored | length == 1' >/dev/null
  [ "$(cat "$REPO/.gitignore")" = "node_modules" ]
}

@test "--dry-run reports preview without mutating" {
  bootstrap_with_gitignore_merge
  before="$(cat "$REPO/.gitignore")"
  run bash "$UNDO" --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "preview"' >/dev/null
  # No mutation.
  [ "$(cat "$REPO/.gitignore")" = "$before" ]
}

@test "without --yes the script previews but does not mutate" {
  bootstrap_with_gitignore_merge
  before="$(cat "$REPO/.gitignore")"
  run bash "$UNDO" --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "preview"' >/dev/null
  [ "$(cat "$REPO/.gitignore")" = "$before" ]
}

@test "--scope=docs leaves gitignore-category writes untouched" {
  bootstrap_with_gitignore_merge
  run bash "$UNDO" --target "$REPO" --scope docs --yes
  [ "$status" -eq 0 ]
  # .gitignore should NOT be restored — its category is gitignore, not docs.
  echo "$output" | jq -e '.restored | length == 0' >/dev/null
  echo "$output" | jq -e '.scope_applied == ["docs"]' >/dev/null
}

@test "refused when no boot records exist" {
  run bash "$UNDO" --target "$REPO" --yes
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "refused"' >/dev/null
  echo "$output" | jq -e '.refused_reason | test("no boot records")' >/dev/null
  # BUG E: manifest_path must not be emitted as the literal string "null".
  # When unresolved it is omitted entirely (real JSON, schema-valid).
  echo "$output" | jq -e 'has("manifest_path") | not' >/dev/null
  [[ "$output" != *'"manifest_path": "null"'* ]]
}

@test "refused on cross-target manifest" {
  bootstrap_with_gitignore_merge
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  OTHER="$TMP/other"
  mkdir -p "$OTHER"
  ( cd "$OTHER" && git init -q -b main )
  run bash "$UNDO" --target "$OTHER" --manifest "$manifest" --yes
  [ "$status" -eq 1 ]
  # Portable check: refuses because the manifest file isn't inside the target dir.
  echo "$output" | jq -e '.refused_reason | test("not inside target")' >/dev/null
}

@test "manifest is portable across clone paths" {
  # Reviewer-flagged scenario: a teammate who clones the bootstrap PR
  # into a different filesystem path must still be able to undo.
  bootstrap_with_gitignore_merge
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  # Move the whole repo to a different path to simulate another checkout.
  MOVED="$TMP/moved-clone"
  cp -R "$REPO" "$MOVED"
  moved_manifest="$(find "$MOVED/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  run bash "$UNDO" --target "$MOVED" --manifest "$moved_manifest" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "preview"' >/dev/null
}

@test "refused with unknown --scope value" {
  bootstrap_with_gitignore_merge
  run bash "$UNDO" --target "$REPO" --scope bogus --yes
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.refused_reason | test("unknown scope")' >/dev/null
}

@test "result JSON includes source ('bootstrap' or 'retrofit')" {
  bootstrap_with_gitignore_merge
  run bash "$UNDO" --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "bootstrap"' >/dev/null
}

@test "result source reflects retrofit when manifest was made via --source retrofit" {
  echo "node_modules" > "$REPO/.gitignore"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" \
    --source retrofit >/dev/null 2>&1
  run bash "$UNDO" --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "retrofit"' >/dev/null
}

@test "end-to-end: bootstrap + undo with the typescript-library profile restores the repo" {
  # Use a real profile end-to-end. The repo gets seeded with package.json
  # so detect-stack lands typescript-library territory.
  cat > "$REPO/package.json" <<'JSON'
{"name":"e2e","version":"0.0.1","main":"index.js","scripts":{},"devDependencies":{"typescript":"^5.0.0"}}
JSON
  echo "console.log('hi');" > "$REPO/index.ts"

  PROFILE="${REPO_ROOT}/profiles/typescript-library.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$PROFILE" > "$TMP/docplan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"

  # Minimal plan that only declares .gitignore — bootstrap will still
  # exercise the full pipeline (branches, hook install, etc.) but only
  # writes[]'s declared paths get the preview-blob/post-mutation flow.
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"create","bytes":0}],"commands":[],"remote":[]}
JSON

  run bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$PROFILE" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json"
  [ "$status" -eq 0 ]

  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  [ -f "$manifest" ]
  # Manifest should record the .gitignore that bootstrap created.
  jq -e '[.actions[] | select(.kind=="write" and .path==".gitignore")] | length >= 1' "$manifest" >/dev/null

  # Now undo. The .gitignore that bootstrap created should be removed.
  [ -f "$REPO/.gitignore" ]
  run bash "$UNDO" --target "$REPO" --yes --force
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "undone"' >/dev/null
  # .gitignore was a create — it should be deleted.
  [ ! -f "$REPO/.gitignore" ]
}

@test "preview refuses HEAD-ahead-of-seed (matches --yes behaviour)" {
  # Reviewer-flagged: pre-flight refusal must apply uniformly to dry-run
  # and confirmed runs, otherwise the operator can approve a preview the
  # confirmed run will reject.
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1
  # Stack a real commit on top of the bootstrap seed. Switch to a
  # feature branch first because bootstrap installs a hook that blocks
  # direct commits to main.
  git -C "$REPO" checkout -q -b feat/test-stack
  echo "user-work" > "$REPO/work.txt"
  git -C "$REPO" -c user.name=t -c user.email=t@example.com add work.txt
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --no-verify -m "user work"

  # Dry-run preview MUST refuse, same as --yes would.
  run bash "$UNDO" --target "$REPO" --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.refused_reason | test("ahead of the bootstrap seed commit")' >/dev/null
}

@test "skipped seed-commit does not show up as undone" {
  # Reviewer-flagged: seed_commits_undone[] must record actual undoes,
  # not skipped ones. With no --allow-rebase, seed commits always skip.
  bootstrap_with_gitignore_merge
  run bash "$UNDO" --target "$REPO" --dry-run
  [ "$status" -eq 0 ]
  # If a seed-commit landed in the manifest, it should appear in
  # skipped[] but NOT in seed_commits_undone[].
  has_seed_action="$(jq -e '[.skipped[] | select(.kind=="seed-commit")] | length >= 1' <<<"$output" 2>/dev/null)"
  if [ "$has_seed_action" = "true" ]; then
    echo "$output" | jq -e '.seed_commits_undone == []' >/dev/null
  fi
}

@test "corrupt pre-state blob is detected and skipped" {
  # Reviewer-flagged: the sha-mismatch guard in undo-bootstrap is a
  # critical safety check but had no test coverage.
  bootstrap_with_gitignore_merge
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  # Tamper with the .gitignore pre-state blob (the only one with a non-trivial sha record).
  blob_name="$(jq -r '[.actions[] | select(.kind=="write" and .path==".gitignore" and (.pre_state_blob // null) != null)] | .[0].pre_state_blob' "$manifest")"
  [ "$blob_name" != "null" ]
  blob="$(dirname "$manifest")/pre-state/$blob_name"
  [ -f "$blob" ]
  echo "TAMPERED" > "$blob"
  run bash "$UNDO" --target "$REPO" --yes
  [ "$status" -eq 0 ]
  # The .gitignore restore should be skipped with a sha-mismatch reason.
  echo "$output" | jq -e '[.skipped[] | select(.kind=="write" and (.reason | test("blob sha mismatch")))] | length >= 1' >/dev/null
}

@test "manifest with traversal path is refused at restore time" {
  # Reviewer-flagged P1: defense-in-depth. Even if a malicious manifest
  # somehow made it into the repo, undo must refuse to restore through
  # an escaping path.
  bootstrap_with_gitignore_merge
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  # Inject a hostile action into the manifest.
  jq '.actions += [{kind:"write", category:"gitignore", path:"../../etc/passwd", action:"overwrite", pre_existed:true, pre_state_blob:"0001.bin", pre_state_sha256:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", reversible:true}]' "$manifest" > "$manifest.new"
  mv "$manifest.new" "$manifest"
  run bash "$UNDO" --target "$REPO" --yes --force
  [ "$status" -eq 0 ]
  # The hostile path must surface in skipped[] with an "escapes target" reason.
  echo "$output" | jq -e '[.skipped[] | select(.kind=="write" and .path=="../../etc/passwd" and (.reason | test("escapes target")))] | length >= 1' >/dev/null
}

@test "manifest with traversal pre_state_blob is refused (no out-of-repo file leaks into repo)" {
  # Reviewer-flagged P2 (BUG D): the restore cp reads $pre_state/$blob where
  # $blob comes from the repo-local manifest. A hostile manifest with a
  # `../`-escaping pre_state_blob could copy an arbitrary user-readable file
  # into the repo tree. Legit blobs are always bare NNNN.bin basenames.
  bootstrap_with_gitignore_merge
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"

  # Plant a "secret" outside the repo whose bytes must NOT end up in the repo.
  secret="$TMP/secret.txt"
  echo "TOP-SECRET-CONTENT" > "$secret"

  # The blob path is resolved as "$pre_state/$blob"; craft a traversal that
  # reaches $secret from the pre-state dir. Use a legit in-repo target path so
  # only the blob guard (not the path guard) is exercised.
  pre_state="$(dirname "$manifest")/pre-state"
  rel_to_secret="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$secret" "$pre_state")"

  jq --arg blob "$rel_to_secret" \
    '.actions += [{kind:"write", category:"gitignore", path:"leaked.txt", action:"create", pre_existed:true, pre_state_blob:$blob, pre_state_sha256:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", reversible:true}]' \
    "$manifest" > "$manifest.new"
  mv "$manifest.new" "$manifest"

  run bash "$UNDO" --target "$REPO" --yes --force
  [ "$status" -eq 0 ]
  # The hostile blob must be skipped (bare-basename guard).
  echo "$output" | jq -e '[.skipped[] | select(.kind=="write" and .path=="leaked.txt" and (.reason | test("NNNN.bin|outside pre-state")))] | length >= 1' >/dev/null
  # The secret's content must NOT have been written into the repo.
  [ ! -f "$REPO/leaked.txt" ]
  ! grep -rqF "TOP-SECRET-CONTENT" "$REPO" 2>/dev/null
}

@test "--scope= (empty value) does not crash under set -u" {
  bootstrap_with_gitignore_merge
  # Empty scope value used to die with `raw[@]: unbound variable`.
  run bash "$UNDO" --target "$REPO" --scope= --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "preview"' >/dev/null
}

@test "merge-action plan emits action:'merge' (not 'overwrite')" {
  # Schema/code drift fix: br_finalize_writes must honour the
  # plan-declared action, not collapse every existed:true:true to
  # "overwrite".
  bootstrap_with_gitignore_merge
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  jq -e '[.actions[] | select(.kind=="write" and .path==".gitignore" and .action=="merge")] | length >= 1' "$manifest" >/dev/null
}

@test "undo removes IaC wrapper scripts orphaned in .nyann/hooks/iac/" {
  # Regression: install_iac_phase copies wrapper scripts into
  # .nyann/hooks/iac/, but bootstrap registered neither the dir nor the
  # files for snapshot — undo left all five behind (broken reversal).
  cat > "$TMP/profile.json" <<'JSON'
{"name":"terraform","version":1,"archetype":"infra","stack":{"primary_language":"hcl","framework":"terraform"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"conventions":{"commit_format":"conventional","commit_scopes":[]},"extras":{"editorconfig":false,"github_templates":false,"gitignore":false},"documentation":{"claude_md_mode":"off","doc_targets":[],"scaffold_set":[]},"ci":{"enabled":false}}
JSON
  cat > "$TMP/stack.json" <<'JSON'
{"primary_language": "hcl", "secondary_languages": [], "frameworks": ["terraform"], "package_managers": [], "is_monorepo": false, "claude_md_hints": [], "archetype": "infra"}
JSON
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1

  # All five wrapper scripts should have been written.
  [ -f "$REPO/.nyann/hooks/iac/terraform-fmt.sh" ]
  [ -f "$REPO/.nyann/hooks/iac/terraform-validate.sh" ]
  [ -f "$REPO/.nyann/hooks/iac/tflint.sh" ]
  [ -f "$REPO/.nyann/hooks/iac/tfsec.sh" ]
  [ -f "$REPO/.nyann/hooks/iac/terraform-docs.sh" ]

  # Manifest must record them as create actions so undo can reverse them.
  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  jq -e '[.actions[] | select(.kind=="write" and (.path | test("\\.nyann/hooks/iac/")))] | length == 5' "$manifest" >/dev/null

  run bash "$UNDO" --target "$REPO" --yes --force
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "undone"' >/dev/null
  # Every IaC wrapper script must be gone.
  [ ! -f "$REPO/.nyann/hooks/iac/terraform-fmt.sh" ]
  [ ! -f "$REPO/.nyann/hooks/iac/terraform-validate.sh" ]
  [ ! -f "$REPO/.nyann/hooks/iac/tflint.sh" ]
  [ ! -f "$REPO/.nyann/hooks/iac/tfsec.sh" ]
  [ ! -f "$REPO/.nyann/hooks/iac/terraform-docs.sh" ]
}

@test "undo removes commitlint.config.js even when hook-lists are empty" {
  # Regression: install_jsts_phase always writes commitlint.config.js when
  # --jsts runs (bootstrap fires it for any TS/JS repo), but the file was
  # only snapshotted when the profile enumerated eslint/prettier/commitlint.
  # A TS profile with empty hook lists wrote it but never snapshotted it,
  # so undo orphaned it.
  cat > "$REPO/package.json" <<'JSON'
{"name":"ts-empty","version":"0.0.1","main":"index.js","scripts":{},"devDependencies":{"typescript":"^5.0.0"}}
JSON
  cat > "$TMP/profile.json" <<'JSON'
{"name":"typescript","version":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"conventions":{"commit_format":"conventional","commit_scopes":[]},"extras":{"editorconfig":false,"github_templates":false,"gitignore":false},"documentation":{"claude_md_mode":"off","doc_targets":[],"scaffold_set":[]},"ci":{"enabled":false}}
JSON
  cat > "$TMP/stack.json" <<'JSON'
{"primary_language": "typescript", "secondary_languages": [], "frameworks": [], "package_managers": ["npm"], "is_monorepo": false, "claude_md_hints": [], "archetype": "library"}
JSON
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1

  # jsts phase needs node; skip the assertion path if the file wasn't written
  # (node-missing env), since the bug only manifests when the file is written.
  if [ ! -f "$REPO/commitlint.config.js" ]; then
    skip "commitlint.config.js not written (node missing in this env)"
  fi

  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  jq -e '[.actions[] | select(.kind=="write" and .path=="commitlint.config.js")] | length >= 1' "$manifest" >/dev/null

  run bash "$UNDO" --target "$REPO" --yes --force
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "undone"' >/dev/null
  [ ! -f "$REPO/commitlint.config.js" ]
}

@test "commitlint.config.js is reversed under --scope hooks (not docs)" {
  # Regression: _br_category_for had no commitlint.config.js case, so it
  # defaulted to 'docs' and --scope hooks skipped it.
  cat > "$REPO/package.json" <<'JSON'
{"name":"ts-empty","version":"0.0.1","main":"index.js","scripts":{},"devDependencies":{"typescript":"^5.0.0"}}
JSON
  cat > "$TMP/profile.json" <<'JSON'
{"name":"typescript","version":1,"stack":{"primary_language":"typescript"},"branching":{"strategy":"github-flow","base_branches":["main"]},"hooks":{"pre_commit":[],"commit_msg":[],"pre_push":[]},"conventions":{"commit_format":"conventional","commit_scopes":[]},"extras":{"editorconfig":false,"github_templates":false,"gitignore":false},"documentation":{"claude_md_mode":"off","doc_targets":[],"scaffold_set":[]},"ci":{"enabled":false}}
JSON
  cat > "$TMP/stack.json" <<'JSON'
{"primary_language": "typescript", "secondary_languages": [], "frameworks": [], "package_managers": ["npm"], "is_monorepo": false, "claude_md_hints": [], "archetype": "library"}
JSON
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1

  if [ ! -f "$REPO/commitlint.config.js" ]; then
    skip "commitlint.config.js not written (node missing in this env)"
  fi

  manifest="$(find "$REPO/memory/.nyann/bootstraps" -name manifest.json | head -1)"
  jq -e '[.actions[] | select(.kind=="write" and .path=="commitlint.config.js" and .category=="hooks")] | length >= 1' "$manifest" >/dev/null
}

@test "git-init action is always skipped" {
  # Bootstrap into a fresh dir without pre-existing .git so it fires git-init.
  rm -rf "$REPO"
  mkdir -p "$REPO"
  echo "x" > "$REPO/seed.txt"
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[],"commands":[],"remote":[]}
JSON
  bash "$BOOTSTRAP" \
    --target "$REPO" \
    --plan "$TMP/plan.json" \
    --plan-sha256 "$(plan_sha "$TMP/plan.json")" \
    --profile "$TMP/profile.json" \
    --doc-plan "$TMP/docplan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1
  run bash "$UNDO" --target "$REPO" --yes
  [ "$status" -eq 0 ]
  # git-init action should appear in skipped[]
  echo "$output" | jq -e '[.skipped[] | select(.kind=="git-init")] | length >= 1' >/dev/null
  # .git/ is still present.
  [ -d "$REPO/.git" ]
}
