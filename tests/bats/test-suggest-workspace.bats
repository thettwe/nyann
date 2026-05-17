#!/usr/bin/env bats
# v1.9.0: suggest-profile.sh emits workspace_suggestions[] for monorepos.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUGGEST="${REPO_ROOT}/bin/suggest-profile.sh"
  TMP="$(mktemp -d)"
  TARGET="$TMP/repo"
  mkdir -p "$TARGET"
}

teardown() { rm -rf "$TMP"; }

@test "non-monorepo: workspace_suggestions is an empty array" {
  echo '{"name":"single"}' > "$TARGET/package.json"
  echo "x" > "$TARGET/README.md"
  json=$(bash "$SUGGEST" --target "$TARGET" 2>/dev/null)
  [ "$(echo "$json" | jq -r '.workspace_suggestions | type')" = "array" ]
  [ "$(echo "$json" | jq '.workspace_suggestions | length')" -eq 0 ]
}

@test "pnpm-workspaces monorepo: emits one workspace_suggestions entry per workspace" {
  cat > "$TARGET/package.json" <<'EOF'
{"name":"mono","private":true}
EOF
  cat > "$TARGET/pnpm-workspace.yaml" <<'EOF'
packages:
  - "packages/*"
EOF
  mkdir -p "$TARGET/packages/api" "$TARGET/packages/web"
  echo '{"name":"api"}' > "$TARGET/packages/api/package.json"
  echo '{"name":"web"}' > "$TARGET/packages/web/package.json"

  json=$(bash "$SUGGEST" --target "$TARGET" 2>/dev/null)
  [ "$(echo "$json" | jq '.workspace_suggestions | length')" -eq 2 ]
}

@test "workspace_suggestions entry has path, language, suggestion, confidence" {
  cat > "$TARGET/package.json" <<'EOF'
{"name":"mono","private":true}
EOF
  cat > "$TARGET/pnpm-workspace.yaml" <<'EOF'
packages:
  - "packages/*"
EOF
  mkdir -p "$TARGET/packages/api"
  echo '{"name":"api"}' > "$TARGET/packages/api/package.json"

  json=$(bash "$SUGGEST" --target "$TARGET" 2>/dev/null)
  entry=$(echo "$json" | jq -c '.workspace_suggestions[0]')
  [ "$(echo "$entry" | jq -r '.path')" = "packages/api" ]
  [ -n "$(echo "$entry" | jq -r '.language')" ]
  # suggestion may be null if no profile matches above threshold; that's fine.
  echo "$entry" | jq -e 'has("suggestion")' >/dev/null
  # confidence is an integer 0..100
  conf=$(echo "$entry" | jq '.confidence')
  [ "$conf" -ge 0 ]
  [ "$conf" -le 100 ]
}
