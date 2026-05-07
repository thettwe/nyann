#!/usr/bin/env bats
# bin/{compute-drift,retrofit,doctor}.sh --scope — narrow drift to one or
# more categories.
#
# Covers:
#   - default (no flag) → scope_applied is the canonical 7-element list
#   - --scope=docs → only docs subsystems run; missing[] excludes hooks
#   - --scope=hooks,docs → both checked, others not
#   - unknown scope → rc 1 with a clear error
#   - retrofit text render shows "Scope: ..." line on narrow scopes
#   - doctor --persist + narrow scope → persist auto-skips with warning

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-scope.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

# Reach for nextjs-prototype because it declares husky hooks AND
# scaffold docs + gitignore — so the canonical 7-category split has
# something to detect in each bucket.
profile_path() {
  printf '%s' "${REPO_ROOT}/profiles/nextjs-prototype.json"
}

# --- scope_applied[] field ---------------------------------------------------

@test "compute-drift default scope emits the canonical 7-category list" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)"
  [ "$status" -eq 0 ]
  applied=$(echo "$output" | jq -c '.scope_applied | sort')
  want='["branching","docs","editorconfig","github","gitignore","history","hooks"]'
  [ "$applied" = "$want" ]
}

@test "compute-drift --scope=docs records only docs in scope_applied" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope docs
  [ "$status" -eq 0 ]
  applied=$(echo "$output" | jq -c '.scope_applied')
  [ "$applied" = '["docs"]' ]
}

@test "compute-drift --scope=hooks,docs records both" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope hooks,docs
  [ "$status" -eq 0 ]
  applied=$(echo "$output" | jq -c '.scope_applied | sort')
  [ "$applied" = '["docs","hooks"]' ]
}

@test "compute-drift --scope=all expands to canonical 7 (same as default)" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope all
  [ "$status" -eq 0 ]
  applied=$(echo "$output" | jq -c '.scope_applied | sort')
  want='["branching","docs","editorconfig","github","gitignore","history","hooks"]'
  [ "$applied" = "$want" ]
}

# --- filtering actually narrows the work -------------------------------------

@test "compute-drift --scope=docs does NOT report missing husky hooks" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope docs
  [ "$status" -eq 0 ]
  # nextjs-prototype declares husky hooks. With docs-only scope they
  # must not appear in missing[].
  hits=$(echo "$output" | jq '[.missing[] | select(.kind == "husky-hook" or .kind == "commitlint")] | length')
  [ "$hits" = "0" ]
}

@test "compute-drift --scope=hooks does NOT report missing doc scaffolds" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope hooks
  [ "$status" -eq 0 ]
  hits=$(echo "$output" | jq '[.missing[] | select(.kind == "doc")] | length')
  [ "$hits" = "0" ]
}

@test "compute-drift --scope=docs DOES still report missing CLAUDE.md" {
  # CLAUDE.md presence belongs to the docs scope per the v1.7.0 mapping.
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope docs
  [ "$status" -eq 0 ]
  has_claude=$(echo "$output" | jq '[.missing[] | select(.kind == "claude-md")] | length')
  [ "$has_claude" -ge "1" ]
}

@test "compute-drift --scope=hooks skips the parallel doc subsystems" {
  # find-orphans is the cheapest subsystem to verify by output: when
  # --scope=hooks the orphans payload should equal the inert fallback
  # `{scanned:0, orphans:[]}`.
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope hooks
  [ "$status" -eq 0 ]
  orphans_scanned=$(echo "$output" | jq '.documentation.orphans.scanned')
  [ "$orphans_scanned" = "0" ]
}

@test "compute-drift --scope=hooks skips non_compliant_history scan" {
  ( cd "$REPO" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "bad-subject-no-cc-prefix" )
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope hooks
  [ "$status" -eq 0 ]
  checked=$(echo "$output" | jq '.non_compliant_history.checked')
  [ "$checked" = "0" ]
  offenders=$(echo "$output" | jq '.non_compliant_history.offenders | length')
  [ "$offenders" = "0" ]
}

# --- bad input ---------------------------------------------------------------

@test "compute-drift rejects unknown scope" {
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope dox
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown scope: dox"
}

@test "retrofit rejects unknown scope" {
  run bash "${REPO_ROOT}/bin/retrofit.sh" --target "$REPO" \
    --profile nextjs-prototype --scope notarealscope --report-only
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown scope"
}

@test "doctor rejects unknown scope" {
  run bash "${REPO_ROOT}/bin/doctor.sh" --target "$REPO" \
    --profile nextjs-prototype --scope nope
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown scope"
}

# --- text render reflects narrow scope ---------------------------------------

@test "retrofit text render adds 'Scope:' line on narrow scopes" {
  # retrofit.sh renders to stderr; capture it.
  run bash -c "bash '${REPO_ROOT}/bin/retrofit.sh' --target '$REPO' \
    --profile nextjs-prototype --scope docs --report-only 2>&1 1>/dev/null || true"
  echo "$output" | grep -q "^Scope: docs"
}

@test "retrofit default scope omits the Scope line" {
  run bash -c "bash '${REPO_ROOT}/bin/retrofit.sh' --target '$REPO' \
    --profile nextjs-prototype --report-only 2>&1 1>/dev/null || true"
  ! echo "$output" | grep -q "^Scope:"
}

# --- doctor --persist + narrow scope -----------------------------------------

@test "doctor --persist + narrow scope skips persist with a warning" {
  run bash -c "bash '${REPO_ROOT}/bin/doctor.sh' --target '$REPO' \
    --profile nextjs-prototype --scope docs --persist 2>&1 || true"
  echo "$output" | grep -q "skipping --persist"
  # No memory/health.json should have been created.
  [ ! -f "$REPO/memory/health.json" ]
}

# --- schema integrity --------------------------------------------------------

@test "narrow scope reports CLAUDE.md as 'skipped' rather than 'absent'" {
  # On a repo with no CLAUDE.md and no doc scope requested,
  # claude_md.status should be `skipped` (we didn't check), not
  # `absent` (we checked and the file is missing). Otherwise
  # narrow-scope CI gates fail spuriously on repos that don't yet
  # have a CLAUDE.md.
  run bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope hooks
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.documentation.claude_md.status')" = "skipped" ]
}

@test "narrow scope on a CLAUDE.md-less repo exits 0 when in-scope is clean" {
  # The codex-adversarial-review case: --scope branching on a fresh
  # repo (no CLAUDE.md) used to exit 4 because the absent-CLAUDE.md
  # warning leaked through. With the skipped-vs-absent split it
  # exits 0 — the repo IS clean within the requested scope.
  run bash "${REPO_ROOT}/bin/retrofit.sh" --target "$REPO" \
    --profile nextjs-prototype --report-only --scope branching
  [ "$status" -eq 0 ]
}

@test "scope_applied output validates against drift-report schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  bash "${REPO_ROOT}/bin/compute-drift.sh" --target "$REPO" \
    --profile "$(profile_path)" --scope docs > "$TMP/report.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/drift-report.schema.json" "$TMP/report.json"
}
