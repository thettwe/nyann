#!/usr/bin/env bats
# bin/record-decision.sh — ADR creation, auto-increment, slug derivation.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RD="${REPO_ROOT}/bin/record-decision.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

init_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  echo "$repo"
}

@test "missing --title dies" {
  repo=$(init_repo)
  run bash "$RD" --target "$repo"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "--title"
}

@test "creates ADR-000 in empty dir with derived slug" {
  repo=$(init_repo)
  out=$(bash "$RD" --target "$repo" --title "Use Postgres for the primary datastore" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.number')" -eq 0 ]
  [ "$(echo "$out" | jq -r '.slug')" = "use-postgres-for-the-primary-datastore" ]
  [ "$(echo "$out" | jq -r '.path')" = "docs/decisions/ADR-000-use-postgres-for-the-primary-datastore.md" ]
  [ -f "$repo/docs/decisions/ADR-000-use-postgres-for-the-primary-datastore.md" ]
}

@test "auto-increments when ADR-000 exists" {
  repo=$(init_repo)
  bash "$RD" --target "$repo" --title "First decision" >/dev/null 2>&1
  out=$(bash "$RD" --target "$repo" --title "Second decision" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.number')" -eq 1 ]
  [ -f "$repo/docs/decisions/ADR-001-second-decision.md" ]
}

@test "auto-increment: jumps past existing ADR-042" {
  repo=$(init_repo)
  mkdir -p "$repo/docs/decisions"
  touch "$repo/docs/decisions/ADR-042-old.md"
  out=$(bash "$RD" --target "$repo" --title "New one" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.number')" -eq 43 ]
  [ -f "$repo/docs/decisions/ADR-043-new-one.md" ]
}

@test "template substitution: number, title, date, status" {
  repo=$(init_repo)
  bash "$RD" --target "$repo" --title "Adopt pnpm" --status accepted --date 2026-04-23 >/dev/null 2>&1
  f="$repo/docs/decisions/ADR-000-adopt-pnpm.md"
  [ -f "$f" ]
  grep -F -e "ADR-000" "$f"
  grep -F -e "Adopt pnpm" "$f"
  grep -F -e "date: 2026-04-23" "$f"
  grep -F -e "status: accepted" "$f"
}

@test "--slug override wins over derived slug" {
  repo=$(init_repo)
  out=$(bash "$RD" --target "$repo" --title "Use Postgres" --slug db-choice 2>/dev/null)
  [ "$(echo "$out" | jq -r '.slug')" = "db-choice" ]
  [ -f "$repo/docs/decisions/ADR-000-db-choice.md" ]
}

@test "--dir override writes to a custom location" {
  repo=$(init_repo)
  out=$(bash "$RD" --target "$repo" --title "Choose Redis" --dir "decisions" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.path')" = "decisions/ADR-000-choose-redis.md" ]
  [ -f "$repo/decisions/ADR-000-choose-redis.md" ]
}

@test "--dry-run does not create files" {
  repo=$(init_repo)
  out=$(bash "$RD" --target "$repo" --title "Draft decision" --dry-run 2>/dev/null)
  [ "$(echo "$out" | jq -r '.dry_run')" = "true" ]
  [ ! -f "$repo/docs/decisions/ADR-000-draft-decision.md" ]
  [ ! -d "$repo/docs/decisions" ]
}

@test "invalid status dies" {
  repo=$(init_repo)
  run bash "$RD" --target "$repo" --title "X" --status deprecated
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "proposed|accepted"
}

@test "invalid date format dies" {
  repo=$(init_repo)
  run bash "$RD" --target "$repo" --title "X" --date "April 23 2026"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "YYYY-MM-DD"
}

@test "non-ASCII title needs explicit --slug" {
  repo=$(init_repo)
  run bash "$RD" --target "$repo" --title "カスタム決定"
  # derive_slug would strip all non [a-z0-9-], leaving empty. Expect die.
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "slug"
}

@test "title with forward slash renders verbatim (no sed corruption)" {
  # Regression: `sed "s/{title}/$title/g"` choked on / — split into two
  # commands. The perl+env rewrite preserves the slash.
  repo=$(init_repo)
  bash "$RD" --target "$repo" --title "Use Postgres vs/with SQLite" --slug pg-sqlite >/dev/null 2>&1
  f="$repo/docs/decisions/ADR-000-pg-sqlite.md"
  [ -f "$f" ]
  grep -F -e "Use Postgres vs/with SQLite" "$f"
}

@test "title with ampersand renders literally (no sed back-reference)" {
  # Regression: `&` on sed's replacement half back-references the match,
  # so `Use & vs AND` rendered as `Use {title} vs AND`.
  repo=$(init_repo)
  bash "$RD" --target "$repo" --title "Use & vs AND" --slug amp >/dev/null 2>&1
  f="$repo/docs/decisions/ADR-000-amp.md"
  [ -f "$f" ]
  grep -F -e "Use & vs AND" "$f"
  # The literal placeholder should not leak through.
  ! grep -F -e "{title}" "$f"
}

@test "title with backslash survives" {
  repo=$(init_repo)
  bash "$RD" --target "$repo" --title 'Choose path\to\victory' --slug backslash >/dev/null 2>&1
  f="$repo/docs/decisions/ADR-000-backslash.md"
  [ -f "$f" ]
  grep -F -e 'Choose path\to\victory' "$f"
}
