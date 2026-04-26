#!/usr/bin/env bats
# Regressions for hook merge ordering (nyann guard must run before user
# content) and the JSON-based command parser (paths with spaces must
# not be truncated).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL="${REPO_ROOT}/bin/install-hooks.sh"
  HOOK="${REPO_ROOT}/bin/claude-hook-block-main.sh"
  TMP="$(mktemp -d -t nyann-r2regr.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
}

teardown() { rm -rf "$TMP"; }

# ---- nyann guard runs BEFORE user content ------------------------------------

@test "merged hook runs nyann marker before user content" {
  repo="$TMP/repo"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main )

  # Plant a user hook whose only meaningful operation is `exit 0` — the
  # pattern that used to bypass gitleaks in the old merge order. We
  # also plant a sentinel so we can detect whether the nyann guard ran.
  cat > "$repo/.git/hooks/pre-commit" <<HOOK
#!/usr/bin/env bash
touch "$TMP/USER-HOOK-RAN"
exit 0
HOOK
  chmod +x "$repo/.git/hooks/pre-commit"

  run bash "$INSTALL" --target "$repo" --core
  [ "$status" -eq 0 ]

  # The merged hook must place the nyann-managed marker above the
  # user-hook exec. Take line numbers.
  nyann_line=$(grep -n 'nyann-managed-hook' "$repo/.git/hooks/pre-commit" | head -1 | cut -d: -f1)
  user_line=$(grep -n "exec " "$repo/.git/hooks/pre-commit" | head -1 | cut -d: -f1)
  [ -n "$nyann_line" ]
  [ -n "$user_line" ]
  # nyann marker appears BEFORE the exec-chain into user backup.
  [ "$nyann_line" -lt "$user_line" ]

  # The user's original logic is preserved in the backup.
  [ -f "$repo/.git/hooks/pre-commit.pre-nyann" ]
  grep -Fq "USER-HOOK-RAN" "$repo/.git/hooks/pre-commit.pre-nyann"
}

@test "merged hook without a user backup still runs nyann content" {
  repo="$TMP/repo-nouser"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main )
  # No existing pre-commit hook — fresh install path.
  run bash "$INSTALL" --target "$repo" --core
  [ "$status" -eq 0 ]
  [ -f "$repo/.git/hooks/pre-commit" ]
  grep -Fq 'nyann-managed-hook' "$repo/.git/hooks/pre-commit"
  # No exec line, since there's no backup to chain into.
  ! grep -Eq '^exec ' "$repo/.git/hooks/pre-commit"
}

# ---- path-with-space does not break the parser -------------------------------

@test "git -C /path/with spaces commit on main still blocks" {
  # Create a repo at a path with a space in its name; simulate a hook
  # invocation with `git -C "<that path>" commit` via the Claude Code
  # hook entry point.
  repo_with_space="$TMP/My Project"
  mkdir -p "$repo_with_space"
  ( cd "$repo_with_space" \
      && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )

  # Pass via stdin JSON (the Claude Code contract).
  cmd="git -C \"$repo_with_space\" commit -m 'bypass attempt'"
  json_input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')

  run bash -c "printf '%s' '$json_input' | bash '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Blocked"* ]]
}

@test "git -C /path/with spaces on feature branch does NOT block" {
  repo_with_space="$TMP/Feature Repo"
  mkdir -p "$repo_with_space"
  ( cd "$repo_with_space" \
      && git init -q -b main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" \
      && git checkout -q -b feat/x )

  cmd="git -C \"$repo_with_space\" commit -m 'ok'"
  json_input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')

  run bash -c "printf '%s' '$json_input' | bash '$HOOK'"
  [ "$status" -eq 0 ]
}
