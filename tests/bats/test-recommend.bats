#!/usr/bin/env bats
# bin/recommend-branch.sh — strategy selection across synthetic fixtures.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DETECT="${REPO_ROOT}/bin/detect-stack.sh"
  RECOMMEND="${REPO_ROOT}/bin/recommend-branch.sh"
  SCHEMA="${REPO_ROOT}/schemas/branching-choice.schema.json"
}

make_stack() { printf '%s' "$1"; }

@test "jsts-empty (next, no CHANGELOG) → github-flow" {
  run bash -c "bash '$DETECT' --path '${REPO_ROOT}/tests/fixtures/jsts-empty' | bash '$RECOMMEND'"
  [ "$status" -eq 0 ]
  rec=$(echo "$output" | jq -r '.recommendation')
  [ "$rec" = "github-flow" ]
}

@test "CHANGELOG + semver tags → gitflow" {
  stack='{"primary_language":"python","secondary_languages":[],"framework":null,"package_manager":"poetry","is_monorepo":false,"monorepo_tool":null,"has_git":true,"git_is_empty_repo":false,"has_claude_md":false,"existing_precommit_config":"none","existing_ci":"none","contributor_count":2,"has_changelog":true,"has_semver_tags":true,"confidence":0.65,"reasoning":[]}'
  run bash -c "echo '$stack' | bash '$RECOMMEND'"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.recommendation')" = "gitflow" ]
  [ "$(echo "$output" | jq -r '.needs_user_confirm')" = "true" ]
}

@test "monorepo + >5 contributors → trunk-based" {
  stack='{"primary_language":"typescript","secondary_languages":[],"framework":"next","package_manager":"pnpm","is_monorepo":true,"monorepo_tool":"turbo","has_git":true,"git_is_empty_repo":false,"has_claude_md":false,"existing_precommit_config":"none","existing_ci":"none","contributor_count":8,"has_changelog":false,"has_semver_tags":false,"confidence":0.8,"reasoning":[]}'
  run bash -c "echo '$stack' | bash '$RECOMMEND'"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.recommendation')" = "trunk-based" ]
}

@test "output validates against BranchingChoice schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "need uvx or check-jsonschema installed"
  fi
  validator=(uvx --quiet check-jsonschema)
  command -v check-jsonschema >/dev/null && validator=(check-jsonschema)

  tmp=$(mktemp)
  bash -c "bash '$DETECT' --path '${REPO_ROOT}/tests/fixtures/jsts-empty' | bash '$RECOMMEND'" > "$tmp"
  run "${validator[@]}" --schemafile "$SCHEMA" "$tmp"
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}
