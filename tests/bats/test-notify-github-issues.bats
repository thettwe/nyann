#!/usr/bin/env bats
# GitHub issue digest channel (bin/notify-channels/github-issues.sh).
# gh is a PATH stub capturing argv + comment bodies; behavior is driven by
# env markers so create/list/comment paths can each be exercised. Covers the
# digest model (one issue, comments per batch), soft-skips, markdown/mention
# injection hardening, and the exit contract.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-ghis.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  CH="$REPO_ROOT/bin/notify-channels/github-issues.sh"

  GH_LOG="$TMP/gh.log"
  GH_ISSUES="$TMP/issues.json"
  GH_COMMENT_BODY="$TMP/comment.body"
  export GH_LOG GH_ISSUES GH_COMMENT_BODY
  export GH_AUTH_RC=0 GH_CREATE_FAIL_WITH_LABELS=0 GH_COMMENT_RC=0

  STUB="$TMP/stub"
  mkdir -p "$STUB"
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status") exit "${GH_AUTH_RC:-0}" ;;
  "issue list")  cat "$GH_ISSUES" 2>/dev/null || echo "[]"; exit 0 ;;
  "issue create")
    if [[ "${GH_CREATE_FAIL_WITH_LABELS:-0}" == "1" && "$*" == *"--label"* ]]; then
      exit 1
    fi
    echo "https://github.com/o/r/issues/7"; exit 0 ;;
  "issue comment")
    cat >> "$GH_COMMENT_BODY"
    exit "${GH_COMMENT_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$STUB/gh"

  BATCH='[{"timestamp":"2026-06-27T00:00:00Z","source":"sentinel","severity":"critical","message":"PR #42: CI failed","context":{"pr":42,"repo":"o/r"}}]'
}

teardown() { rm -rf "$TMP"; }

send() { # args pass through; batch on stdin
  printf '%s' "${1-$BATCH}" | PATH="$STUB:$PATH" bash "$CH" --repo o/r "${@:2}" 2>&1
}

# gh_absent_path — a minimal PATH with what the channel needs and NO gh, so
# "no gh installed" holds even on machines where gh sits next to coreutils.
# Allowlist rather than a real-PATH mirror: giant runner PATHs are slow to
# mirror and their dangling symlinks make the `[ -e ] || ln -s` idiom fail.
gh_absent_path() {
  local dir="$TMP/nogh" t p
  mkdir -p "$dir"
  for t in bash jq cat sed grep dirname basename head tr date hostname; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -s "$p" "$dir/$t" 2>/dev/null || true
  done
  printf '%s' "$dir"
}

@test "missing gh soft-skips with 75" {
  run bash -c 'printf "%s" "$1" | PATH="$2" bash "$3" --repo o/r' _ "$BATCH" "$(gh_absent_path)" "$CH"
  [ "$status" -eq 75 ]
  echo "$output" | grep -q "not installed"
}

@test "unauthenticated gh soft-skips with 75" {
  export GH_AUTH_RC=1
  run send
  [ "$status" -eq 75 ]
  echo "$output" | grep -q "not authenticated"
}

@test "invalid repo slug soft-skips with 75" {
  run bash -c 'printf "%s" "$1" | PATH="$2:$PATH" bash "$3" --repo "--danger"' _ "$BATCH" "$STUB" "$CH"
  [ "$status" -eq 75 ]
  echo "$output" | grep -q "invalid repo slug"
}

@test "empty batch is a no-op success" {
  run send "[]"
  [ "$status" -eq 0 ]
  [ ! -f "$GH_COMMENT_BODY" ]
}

@test "no digest issue → created once (title + labels) then commented" {
  echo "[]" > "$GH_ISSUES"
  run send "$BATCH" --labels nyann-sentinel
  [ "$status" -eq 0 ]
  grep -q "issue create --repo o/r --title nyann sentinel digest" "$GH_LOG"
  grep -q -- "--label nyann-sentinel" "$GH_LOG"
  grep -q "issue comment 7 --repo o/r" "$GH_LOG"
  grep -q "nyann sentinel —" "$GH_COMMENT_BODY"
}

@test "existing digest issue (matched by exact title) is reused — no create" {
  jq -n '[{number: 12, title: "nyann sentinel digest"}, {number: 3, title: "nyann sentinel digest FAQ"}]' > "$GH_ISSUES"
  run send
  [ "$status" -eq 0 ]
  ! grep -q "issue create" "$GH_LOG"
  grep -q "issue comment 12" "$GH_LOG"
}

@test "create with a missing label retries unlabeled" {
  echo "[]" > "$GH_ISSUES"
  export GH_CREATE_FAIL_WITH_LABELS=1
  run send "$BATCH" --labels ghost-label
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "retrying without labels"
  [ "$(grep -c "issue create" "$GH_LOG")" -eq 2 ]
  grep -q "issue comment 7" "$GH_LOG"
}

@test "comment body carries severity, repo tag, code-span message, and PR number" {
  jq -n '[{number: 5, title: "nyann sentinel digest"}]' > "$GH_ISSUES"
  run send
  [ "$status" -eq 0 ]
  grep -q -- '- \*\*\[critical\]\*\* \[o/r\] `PR #42: CI failed` (PR #42)' "$GH_COMMENT_BODY"
}

@test "markdown/mention injection: backticks, newlines and @mentions are neutralized" {
  jq -n '[{number: 5, title: "nyann sentinel digest"}]' > "$GH_ISSUES"
  evil='[{"severity":"critical","message":"x` @admin\n\n# fake heading `y","context":{"pr":1}}]'
  run send "$evil"
  [ "$status" -eq 0 ]
  # The message stays ONE list line wrapped in exactly one code span: the
  # payload's own backticks were stripped (else they would close the span
  # early and let the @mention/heading escape into live markdown).
  line=$(grep -- '\*\*\[critical\]\*\*' "$GH_COMMENT_BODY")
  [ "$(printf '%s' "$line" | tr -cd '`' | wc -c | tr -d ' ')" -eq 2 ]
  printf '%s' "$line" | grep -q '@admin'
  # No injected heading line escaped the span.
  ! grep -q '^# fake heading' "$GH_COMMENT_BODY"
}

@test "failed comment post returns non-zero (batch retried, not marked)" {
  jq -n '[{number: 5, title: "nyann sentinel digest"}]' > "$GH_ISSUES"
  export GH_COMMENT_RC=1
  run send
  [ "$status" -ne 0 ]
  [ "$status" -ne 75 ]
  echo "$output" | grep -q "failed to comment"
}
