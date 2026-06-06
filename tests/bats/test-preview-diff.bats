#!/usr/bin/env bats
# bin/preview.sh diff for merge actions, plus bin/render-plan.sh + the
# --output flags on gitignore-combiner.sh / gen-claudemd.sh.
#
# Covers:
#   - gitignore-combiner --output writes a complete merged file
#     identical to what in-place mutation produces
#   - gen-claudemd --output respects markers in $target/CLAUDE.md
#     while writing to a different path
#   - render-plan.sh adds preview_blob + current_bytes to merge entries
#     it knows how to render, leaves create entries alone
#   - preview.sh shows a unified diff for merge entries with preview_blob
#   - preview.sh --no-diff suppresses the diff block
#   - preview.sh --full-diff shows hunks past the truncation cap
#   - new schema fields validate against action-plan.schema.json

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-prev-diff.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

# --- gitignore-combiner --output --------------------------------------------

@test "gitignore-combiner --output writes the same bytes as in-place" {
  cat > "$REPO/.gitignore" <<'EOF'
# my own
.DS_Store
EOF

  # In-place run produces the canonical bytes.
  cp "$REPO/.gitignore" "$TMP/before"
  bash "${REPO_ROOT}/bin/gitignore-combiner.sh" --target "$REPO/.gitignore" \
    --templates jsts >/dev/null
  cp "$REPO/.gitignore" "$TMP/in-place"

  # Restore the original and run with --output to a side path.
  cp "$TMP/before" "$REPO/.gitignore"
  bash "${REPO_ROOT}/bin/gitignore-combiner.sh" --target "$REPO/.gitignore" \
    --output "$TMP/rendered" --templates jsts >/dev/null

  diff -u "$TMP/in-place" "$TMP/rendered"
  # And the in-place target was untouched by the --output run.
  diff -u "$TMP/before" "$REPO/.gitignore"
}

@test "gitignore-combiner --output rejects --output==--target" {
  : > "$REPO/.gitignore"
  run bash "${REPO_ROOT}/bin/gitignore-combiner.sh" --target "$REPO/.gitignore" \
    --output "$REPO/.gitignore" --templates jsts
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must differ"
}

@test "gitignore-combiner --output works on a fresh target (no existing file)" {
  bash "${REPO_ROOT}/bin/gitignore-combiner.sh" --target "$REPO/.gitignore" \
    --output "$TMP/rendered" --templates jsts >/dev/null
  [ -s "$TMP/rendered" ]
  # In-place run on a fresh repo for comparison.
  bash "${REPO_ROOT}/bin/gitignore-combiner.sh" --target "$REPO/.gitignore" \
    --templates jsts >/dev/null
  diff -u "$REPO/.gitignore" "$TMP/rendered"
}

# --- gen-claudemd --output ---------------------------------------------------

@test "gen-claudemd --output writes the same bytes as in-place when CLAUDE.md exists" {
  # Seed a profile + doc plan + stack triple just thorough enough for
  # gen-claudemd to render.
  profile="${REPO_ROOT}/profiles/default.json"
  doc_plan="$TMP/doc-plan.json"
  bash "${REPO_ROOT}/bin/route-docs.sh" --profile "$profile" > "$doc_plan"

  # First in-place — captures the canonical bytes.
  cat > "$REPO/CLAUDE.md" <<'EOF'
# my repo
some user content above the markers.

<!-- nyann:start -->
old block to be replaced
<!-- nyann:end -->

below content.
EOF
  cp "$REPO/CLAUDE.md" "$TMP/before"
  bash "${REPO_ROOT}/bin/gen-claudemd.sh" --profile "$profile" \
    --doc-plan "$doc_plan" --target "$REPO" >/dev/null
  cp "$REPO/CLAUDE.md" "$TMP/in-place"

  # Now restore + render with --output.
  cp "$TMP/before" "$REPO/CLAUDE.md"
  bash "${REPO_ROOT}/bin/gen-claudemd.sh" --profile "$profile" \
    --doc-plan "$doc_plan" --target "$REPO" --output "$TMP/rendered" >/dev/null

  diff -u "$TMP/in-place" "$TMP/rendered"
  diff -u "$TMP/before"   "$REPO/CLAUDE.md"
}

# --- render-plan.sh ----------------------------------------------------------

@test "render-plan adds preview_blob + current_bytes to gitignore merge entries" {
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  cat > "$TMP/plan.json" <<'JSON'
{
  "writes": [
    {"path": ".gitignore", "action": "merge", "bytes": 0},
    {"path": "newfile.md",  "action": "create", "bytes": 100}
  ],
  "commands": [],
  "remote": []
}
JSON

  rendered=$(bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --templates-csv jsts)

  # The .gitignore merge entry now carries preview_blob and current_bytes.
  blob=$(echo "$rendered" | jq -r '.writes[0].preview_blob')
  cur=$(echo "$rendered"  | jq '.writes[0].current_bytes')
  [ -n "$blob" ]
  [ -f "$blob" ]
  [ "$cur" -gt 0 ]
  # The create entry is unchanged.
  [ "$(echo "$rendered" | jq '.writes[1] | has("preview_blob")')" = "false" ]
}

@test "render-plan leaves merge entries alone when no renderer matches" {
  cat > "$TMP/plan.json" <<'JSON'
{
  "writes": [
    {"path": "weird-merge-target.toml", "action": "merge", "bytes": 0}
  ],
  "commands": [],
  "remote": []
}
JSON
  rendered=$(bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO")
  [ "$(echo "$rendered" | jq '.writes[0] | has("preview_blob")')" = "false" ]
}

@test "render-plan accepts a caller-supplied --tmpdir" {
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  mkdir "$TMP/blobs"
  rendered=$(bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --tmpdir "$TMP/blobs" \
    --templates-csv jsts)
  blob=$(echo "$rendered" | jq -r '.writes[0].preview_blob')
  case "$blob" in
    "$TMP/blobs/"*) : ;;
    *) echo "blob not under caller tmpdir: $blob"; exit 1 ;;
  esac
}

# --- preview.sh diff rendering ----------------------------------------------

@test "preview prints a diff block for merge entries with preview_blob" {
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  rendered_plan="$TMP/rendered.json"
  bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --templates-csv jsts \
    > "$rendered_plan"

  # Preview from inside the repo so the relative .path resolves.
  out=$(cd "$REPO" && bash "${REPO_ROOT}/bin/preview.sh" --plan "$rendered_plan" 2>&1 1>/dev/null || true)
  echo "$out" | grep -q "diff (current"
  # And the body shows lines added by the jsts template within the
  # default 20-line truncation cap (yarn-debug appears in the first
  # block; node_modules sits past line 20 and would be hidden).
  echo "$out" | grep -q "yarn-debug"
}

@test "preview --no-diff suppresses the diff block" {
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  rendered_plan="$TMP/rendered.json"
  bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --templates-csv jsts \
    > "$rendered_plan"

  out=$(cd "$REPO" && bash "${REPO_ROOT}/bin/preview.sh" --plan "$rendered_plan" --no-diff 2>&1 1>/dev/null || true)
  ! echo "$out" | grep -q "diff (current"
}

@test "preview --target resolves diff path when invoked from outside the repo" {
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  rendered_plan="$TMP/rendered.json"
  bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --templates-csv jsts \
    > "$rendered_plan"

  # Run preview from somewhere OTHER than $REPO. Without --target the
  # renderer would diff against /dev/null and dump the whole blob.
  out=$(cd "$TMP" && bash "${REPO_ROOT}/bin/preview.sh" \
    --plan "$rendered_plan" --target "$REPO" 2>&1 1>/dev/null || true)
  echo "$out" | grep -q "diff (current"
  # The base file (.gitignore with .DS_Store) must appear as the
  # `---` side of the diff, not /dev/null.
  ! echo "$out" | grep -q "/dev/null"
}

@test "preview --full-diff disables truncation" {
  # Build a plan whose merge has many added lines (>20) so the auto
  # truncate would otherwise hide them. We synthesise the blob by
  # hand to keep the test independent of template content.
  : > "$REPO/.gitignore"
  blob="$TMP/big-blob"
  printf '%s\n' .DS_Store > "$blob"
  for i in $(seq 1 40); do printf 'line-%02d\n' "$i" >> "$blob"; done

  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":".gitignore","action":"merge","bytes":0,"preview_blob":"$blob","current_bytes":0}],"commands":[],"remote":[]}
JSON

  out_full=$(cd "$REPO" && bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" --full-diff 2>&1 1>/dev/null || true)
  out_auto=$(cd "$REPO" && bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json"             2>&1 1>/dev/null || true)

  # Full diff shows line-40; auto truncates and mentions the truncation.
  echo "$out_full" | grep -q "line-40"
  echo "$out_auto" | grep -q "truncated"
  ! echo "$out_auto" | grep -q "line-40"
}

# --- unresolved-target misrepresentation guard -------------------------------

@test "merge with existing target but unresolved path does not render a bare /dev/null create" {
  # Regression: a merge entry whose render-plan reports current_bytes > 0
  # (the target file really exists) but whose path can't be located —
  # no --target, no NYANN_PREVIEW_TARGET, cwd != repo root — must NOT
  # diff against /dev/null. Doing so dumps the whole merged blob as
  # additions, making an append-merge look like a brand-new file while
  # the header still claims "current N B". Preview must warn instead.
  blob="$TMP/merged-blob"
  printf '%s\n' .DS_Store node_modules > "$blob"

  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":".gitignore","action":"merge","bytes":0,"preview_blob":"$blob","current_bytes":42}],"commands":[],"remote":[]}
JSON

  # Run from $TMP (NOT $REPO) and pass no --target. The .gitignore path
  # is unresolvable from here, but current_bytes says it exists.
  out=$(cd "$TMP" && bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/plan.json" 2>&1 1>/dev/null || true)

  # No misleading "diff (current 42 B → merged)" header.
  ! echo "$out" | grep -q "diff (current 42 B"
  # No /dev/null full-file create dumped as additions.
  ! echo "$out" | grep -q "/dev/null"
  # Instead: a clear warning telling the operator to pass --target.
  echo "$out" | grep -q "diff unavailable"
  echo "$out" | grep -q -- "--target"
}

@test "merge with existing target still shows a partial diff when --target is passed" {
  # Counterpart to the guard above: when --target DOES resolve the file,
  # preview shows the real partial diff (not a full create), confirming
  # the guard only fires on the unresolved case.
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  blob="$TMP/merged-blob"
  printf '%s\n' .DS_Store node_modules > "$blob"
  bytes=$(wc -c < "$REPO/.gitignore" | tr -d ' ')

  cat > "$TMP/plan.json" <<JSON
{"writes":[{"path":".gitignore","action":"merge","bytes":0,"preview_blob":"$blob","current_bytes":$bytes}],"commands":[],"remote":[]}
JSON

  out=$(cd "$TMP" && bash "${REPO_ROOT}/bin/preview.sh" \
    --plan "$TMP/plan.json" --target "$REPO" 2>&1 1>/dev/null || true)

  # Real diff header, no warning, no /dev/null base.
  echo "$out" | grep -q "diff (current"
  ! echo "$out" | grep -q "diff unavailable"
  ! echo "$out" | grep -q "/dev/null"
  # node_modules is the added line; .DS_Store is the unchanged context.
  echo "$out" | grep -q "node_modules"
}

# --- TOCTOU: bootstrap consumes the blob, not the live repo state -----------

@test "bootstrap copies .gitignore from preview_blob when present" {
  # Adversarial scenario: between preview-time and execute-time, an
  # outside actor edits the live .gitignore. Bootstrap must ship the
  # blob the user approved, not re-render against tampered live state.
  # Otherwise the SHA binding is meaningless for merge actions — the
  # plan SHA matches but the on-disk bytes don't.
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  # Build a minimal plan that just merges .gitignore.
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --templates-csv jsts \
    > "$TMP/rendered.json"

  # Capture the rendered blob's expected post-merge SHA.
  blob_path=$(jq -r '.writes[0].preview_blob' "$TMP/rendered.json")
  expected=$(shasum -a 256 "$blob_path" | awk '{print $1}')

  # Adversary tampering: rewrite the live .gitignore with content the
  # render-plan blob does NOT include. If bootstrap re-rendered, it'd
  # incorporate this content; if it cps the blob, the live edit is
  # silently overwritten by the previewed bytes (correct behaviour).
  printf 'tampered-by-adversary\n' >> "$REPO/.gitignore"

  # Drive bootstrap (skip irrelevant steps via env / minimal plan).
  # Use the rendered plan's SHA-256 binding so the integrity check
  # passes and execution proceeds.
  sha=$(bash "${REPO_ROOT}/bin/preview.sh" --plan "$TMP/rendered.json" --emit-sha256 2>/dev/null)

  # Use a fresh profile + doc-plan because bootstrap requires both.
  bash "${REPO_ROOT}/bin/route-docs.sh" \
    --profile "${REPO_ROOT}/profiles/default.json" > "$TMP/doc-plan.json"
  bash "${REPO_ROOT}/bin/detect-stack.sh" --path "$REPO" > "$TMP/stack.json"

  bash "${REPO_ROOT}/bin/bootstrap.sh" \
    --plan "$TMP/rendered.json" --plan-sha256 "$sha" \
    --target "$REPO" \
    --profile "${REPO_ROOT}/profiles/default.json" \
    --doc-plan "$TMP/doc-plan.json" \
    --stack "$TMP/stack.json" >/dev/null 2>&1 || true

  actual=$(shasum -a 256 "$REPO/.gitignore" | awk '{print $1}')
  [ "$actual" = "$expected" ]
  # And the adversary's tampered line must not appear.
  ! grep -q "tampered-by-adversary" "$REPO/.gitignore"
}

# --- schema integrity --------------------------------------------------------

@test "rendered plan validates against action-plan schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  cat > "$REPO/.gitignore" <<'EOF'
.DS_Store
EOF
  cat > "$TMP/plan.json" <<'JSON'
{"writes":[{"path":".gitignore","action":"merge","bytes":0}],"commands":[],"remote":[]}
JSON
  bash "${REPO_ROOT}/bin/render-plan.sh" \
    --plan "$TMP/plan.json" --target "$REPO" --templates-csv jsts \
    > "$TMP/rendered.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/action-plan.schema.json" "$TMP/rendered.json"
}
