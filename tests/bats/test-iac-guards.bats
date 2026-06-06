#!/usr/bin/env bats
# bin/guards/{unpinned-iac-refs,committed-secrets}.sh — IaC pre-action guards,
# and their wiring into bin/pre-action-guard.sh (commit + release flows).
#
# Per-test ephemeral git repo (like test-iac-drift.bats) so the committed-only
# secrets gate sees real tracked files.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-iac-guards.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q -b main \
      && git config user.email t@t \
      && git config user.name  t \
      && git commit -q --allow-empty -m seed )
}

teardown() { rm -rf "$TMP"; }

commit_all() { ( cd "$REPO" && git add -A && git commit -q -m fixture ); }

# --- unpinned-iac-refs guard (direct) ---------------------------------------

@test "unpinned-iac-refs: clean on non-IaC repo (soft-skip, advisory pass)" {
  echo "# readme" > "$REPO/README.md"
  commit_all
  run bash "$REPO_ROOT/bin/guards/unpinned-iac-refs.sh" "$REPO" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name == "unpinned-iac-refs" and .pass == true and .severity == "advisory"'
}

@test "unpinned-iac-refs: fails advisory on a moving module ref" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  commit_all
  run bash "$REPO_ROOT/bin/guards/unpinned-iac-refs.sh" "$REPO" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == false and .severity == "advisory"'
  echo "$output" | jq -e '.message | contains("unpinned IaC ref")'
}

@test "unpinned-iac-refs: passes when refs are pinned" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=v1.2.0" }
EOF
  commit_all
  run bash "$REPO_ROOT/bin/guards/unpinned-iac-refs.sh" "$REPO" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
}

@test "unpinned-iac-refs: profile-disabled detector soft-skips" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  commit_all
  prof="$TMP/p.json"
  jq -n '{iac:{drift_check:{enabled:true, unpinned_refs:false}}}' > "$prof"
  run bash "$REPO_ROOT/bin/guards/unpinned-iac-refs.sh" "$REPO" main "$prof"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true and .skipped == true'
}

@test "unpinned-iac-refs: non-git dir soft-skips" {
  nonrepo="$TMP/plain"
  mkdir -p "$nonrepo"
  run bash "$REPO_ROOT/bin/guards/unpinned-iac-refs.sh" "$nonrepo" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped == true'
}

# --- committed-secrets guard (direct) ---------------------------------------

@test "committed-secrets: critical fail on committed AWS key in tfvars" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  run bash "$REPO_ROOT/bin/guards/committed-secrets.sh" "$REPO" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name == "committed-secrets" and .pass == false and .severity == "critical"'
  # The guard message must not leak the raw secret.
  echo "$output" | jq -e '(.message // "") | contains("AKIAIOSFODNN7EXAMPLE") | not'
}

@test "committed-secrets: passes (critical floor) when no committed secrets" {
  echo "region = \"us-east-1\"" > "$REPO/prod.tfvars"
  commit_all
  run bash "$REPO_ROOT/bin/guards/committed-secrets.sh" "$REPO" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true and .severity == "critical"'
}

@test "committed-secrets: gitignored secret NOT flagged" {
  cat > "$REPO/secret.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  echo "secret.tfvars" > "$REPO/.gitignore"
  commit_all
  run bash "$REPO_ROOT/bin/guards/committed-secrets.sh" "$REPO" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true'
}

@test "committed-secrets: profile-demotable via secrets_in_vars=false (soft-skip)" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  prof="$TMP/p.json"
  jq -n '{iac:{drift_check:{enabled:true, secrets_in_vars:false}}}' > "$prof"
  run bash "$REPO_ROOT/bin/guards/committed-secrets.sh" "$REPO" main "$prof"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pass == true and .skipped == true and .severity == "critical"'
}

@test "committed-secrets: re-emits critical severity even when soft-skipping non-git dir" {
  nonrepo="$TMP/plain"
  mkdir -p "$nonrepo"
  run bash "$REPO_ROOT/bin/guards/committed-secrets.sh" "$nonrepo" main
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.skipped == true and .severity == "critical"'
}

# --- orchestrator wiring ----------------------------------------------------

@test "commit flow registers unpinned-iac-refs" {
  echo "x" > "$REPO/x.txt"
  ( cd "$REPO" && git add x.txt )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.guards[].name] | index("unpinned-iac-refs") != null'
}

@test "release flow registers committed-secrets and unpinned-iac-refs" {
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow release --target "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.guards[].name] | index("committed-secrets") != null'
  echo "$output" | jq -e '[.guards[].name] | index("unpinned-iac-refs") != null'
}

@test "release flow: committed secret blocks critical (exit 3)" {
  # Clean tree (clean-tree passes), but a committed secret in a tfvars file
  # must trip committed-secrets at critical → exit 3.
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow release --target "$REPO"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.pass == false'
  echo "$output" | jq -e '.guards[] | select(.name == "committed-secrets") | .pass == false and .severity == "critical"'
}

@test "release flow: profile demotes secrets gate (no longer blocks)" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  prof="$TMP/p.json"
  jq -n '{iac:{drift_check:{enabled:true, secrets_in_vars:false}}}' > "$prof"
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow release --target "$REPO" --profile "$prof"
  # Profile is forwarded to the guard, which soft-skips → release no longer
  # blocks on the secret (exit 0, committed-secrets skipped).
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.guards[] | select(.name == "committed-secrets") | .skipped == true'
}

@test "commit flow: unpinned ref is advisory only (does not block)" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  ( cd "$REPO" && git add main.tf )
  run bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow commit --target "$REPO"
  # unpinned-iac-refs fails advisory; staged-files-exist passes. Advisory
  # failures don't block → exit 0.
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.guards[] | select(.name == "unpinned-iac-refs") | .pass == false and .severity == "advisory"'
}

@test "guard-result JSON (release flow with IaC guards) validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  bash "$REPO_ROOT/bin/pre-action-guard.sh" --flow release --target "$REPO" > "$TMP/result.json" || true
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/guard-result.schema.json" "$TMP/result.json"
}
