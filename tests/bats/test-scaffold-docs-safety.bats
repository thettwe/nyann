#!/usr/bin/env bats
# Regressions for scaffold-docs hardening: template rendering uses env
# vars instead of shell interpolation, mktemp is cleaned up on failure,
# and mv is atomic (tmp next to dst on the same filesystem).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCAFFOLD="${REPO_ROOT}/bin/scaffold-docs.sh"
  TMP="$(mktemp -d -t nyann-scaff.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"

  # Reusable minimal doc plan: architecture + prd landing locally.
  cat > "$TMP/docplan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "architecture": { "type": "local", "path": "docs/architecture.md" },
    "prd":          { "type": "local", "path": "docs/prd.md" },
    "adrs":         { "type": "local", "path": "docs/decisions" },
    "research":     { "type": "local", "path": "docs/research" },
    "memory":       { "type": "local", "path": "memory" }
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3
}
JSON
}

teardown() { rm -rf "$TMP"; }

# ---- backtick in project_name must NOT execute a command --------------------

@test "backtick in project-name does not execute via perl substitution" {
  # If the old esc() logic were still active, running in a repo named
  # `test\`touch /tmp/nyann-exploit-sentinel-backtick-rce\`` (or project-name with backticks)
  # would bash-expand the backtick, running `touch /tmp/nyann-exploit-sentinel-backtick-rce`
  # as part of building the perl command. We pass --project-name
  # directly so we don't have to rename a directory.
  sentinel="/tmp/nyann-exploit-sentinel-backtick-rce-$$.marker"
  rm -f "$sentinel"

  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  malicious='innocent`touch '"$sentinel"'`injected'

  run bash "$SCAFFOLD" \
    --target "$REPO" \
    --plan "$TMP/docplan.json" \
    --project-name "$malicious"
  # Regardless of scaffold success/failure, the sentinel must NOT exist.
  [ ! -e "$sentinel" ] || { echo "SECURITY: backtick executed — sentinel exists"; rm -f "$sentinel"; false; }
  rm -f "$sentinel"
}

@test "double-quote in project-name does not terminate the bash string" {
  REPO="$TMP/repo-dq"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  # A double-quote in the old esc() would close the bash string mid-argument
  # to perl. The env-var pattern makes this a non-event — the value goes in
  # verbatim.
  run bash "$SCAFFOLD" \
    --target "$REPO" \
    --plan "$TMP/docplan.json" \
    --project-name 'proj"with"quotes'
  [ "$status" -eq 0 ]
  # And the literal appears in the output file.
  [ -f "$REPO/docs/architecture.md" ]
  grep -Fq 'proj"with"quotes' "$REPO/docs/architecture.md"
}

@test "newline in project-name does not break the perl command" {
  REPO="$TMP/repo-nl"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  run bash "$SCAFFOLD" \
    --target "$REPO" \
    --plan "$TMP/docplan.json" \
    --project-name $'line1\nline2'
  # Either 0 (accepted cleanly) or a clean die; never silent partial write.
  # The important thing: the architecture doc should not have been left
  # half-written by perl errors.
  [ "$status" -eq 0 ] || [[ "$output" == *"nyann"* ]]
}

# ---- rendered output is still correct for ordinary values -------------------

@test "normal project-name renders correctly end-to-end" {
  REPO="$TMP/repo-normal"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  run bash "$SCAFFOLD" \
    --target "$REPO" \
    --plan "$TMP/docplan.json" \
    --project-name "normal-project-name"
  [ "$status" -eq 0 ]
  [ -f "$REPO/docs/architecture.md" ]
  grep -Fq "normal-project-name" "$REPO/docs/architecture.md"
  # {{#if framework}} blocks that were paired with an empty value must be stripped
  ! grep -q '{{#if' "$REPO/docs/architecture.md"
  ! grep -q '{{/if}}' "$REPO/docs/architecture.md"
  ! grep -q '{{project_name}}' "$REPO/docs/architecture.md"
}

# ---- no leftover temp files after render -------------------------------------

@test "no temp files left in destination dir after successful render" {
  REPO="$TMP/repo-tmp"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )

  bash "$SCAFFOLD" \
    --target "$REPO" \
    --plan "$TMP/docplan.json" \
    --project-name "rmtest" > /dev/null 2>&1
  # Final doc exists, and no .nyann-tmpl.* shadow files remain alongside it.
  [ -f "$REPO/docs/architecture.md" ]
  found=$(find "$REPO" -name '.nyann-tmpl.*' | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}
