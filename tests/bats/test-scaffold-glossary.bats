#!/usr/bin/env bats
# bin/scaffold-glossary.sh — auto-populate the auto block of
# docs/glossary.md from detected exported types in the target repo.
#
# Covers:
#   - Per-language detection (Go, TS, Python, Rust)
#   - --max-terms cap
#   - Idempotent rerun preserves user content outside markers
#   - --force-merge appends to a glossary that lacks markers
#   - JSON mode emits a valid GlossaryDraft
#   - Profile gating: auto_populate=false in the profile means
#     scaffold-docs does NOT call scaffold-glossary

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-glossary.XXXXXX)"
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  ( cd "$REPO" && git init -q -b main )
}

teardown() { rm -rf "$TMP"; }

# --- detection per language -------------------------------------------------

@test "scaffold-glossary detects Go top-level structs and interfaces" {
  mkdir -p "$REPO/src"
  cat > "$REPO/src/main.go" <<'EOF'
package main

type Person struct {
	Name string
}

type Greeter interface {
	Greet() string
}
EOF
  cat > "$REPO/src/use.go" <<'EOF'
package main

func use(p Person, g Greeter) {}
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  out=$(bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages go --json)
  names=$(echo "$out" | jq -r '[.terms[].name] | sort | join(",")')
  [ "$names" = "Greeter,Person" ]
}

@test "scaffold-glossary detects exported TypeScript interfaces and types" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User { id: string }
export type ID = string;
export class Service {}
function privateThing() {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User, Service, ID } from './types'
export function f(u: User, s: Service, id: ID) { return u.id + id + (s as any) }
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  out=$(bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages ts --json)
  # All three exports detected.
  for n in User ID Service; do
    [ "$(echo "$out" | jq --arg n "$n" '[.terms[] | select(.name == $n)] | length')" = "1" ]
  done
  # privateThing is a function, not a type — must NOT show up.
  [ "$(echo "$out" | jq '[.terms[] | select(.name == "privateThing")] | length')" = "0" ]
}

@test "scaffold-glossary detects top-level Python classes" {
  cat > "$REPO/models.py" <<'EOF'
class Person:
    pass

class Greeter:
    pass

def make():
    return Person()
EOF
  cat > "$REPO/use.py" <<'EOF'
from models import Person, Greeter
def f(p: Person, g: Greeter): return p, g
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  out=$(bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages python --json)
  names=$(echo "$out" | jq -r '[.terms[].name] | sort | join(",")')
  [ "$names" = "Greeter,Person" ]
}

@test "scaffold-glossary detects pub Rust structs/traits/enums" {
  cat > "$REPO/lib.rs" <<'EOF'
pub struct Account { id: u64 }

pub trait Greet {
    fn greet(&self) -> String;
}

pub enum Mode { On, Off }

struct Private;
EOF
  cat > "$REPO/main.rs" <<'EOF'
use crate::{Account, Greet, Mode};
fn run(a: Account, g: &dyn Greet, m: Mode) {}
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  out=$(bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages rust --json)
  names=$(echo "$out" | jq -r '[.terms[].name] | sort | join(",")')
  [ "$names" = "Account,Greet,Mode" ]
  # Private struct must not appear.
  [ "$(echo "$out" | jq '[.terms[] | select(.name == "Private")] | length')" = "0" ]
}

# --- cap + ranking ----------------------------------------------------------

@test "scaffold-glossary --max-terms caps the output set" {
  cat > "$REPO/types.ts" <<'EOF'
export interface A {}
export interface B {}
export interface C {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { A, B, C } from './types'
export function f(a: A, b: B, c: C) {}
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  out=$(bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages ts --max-terms 2 --json)
  [ "$(echo "$out" | jq '.terms | length')" = "2" ]
  [ "$(echo "$out" | jq '.total_candidates')" = "3" ]
  [ "$(echo "$out" | jq '.selected')" = "2" ]
}

# --- file write + idempotency -----------------------------------------------

@test "scaffold-glossary creates docs/glossary.md from the template" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" --languages ts >/dev/null
  [ -f "$REPO/docs/glossary.md" ]
  grep -q "<!-- nyann:glossary:auto-start -->" "$REPO/docs/glossary.md"
  grep -q "### User" "$REPO/docs/glossary.md"
}

@test "scaffold-glossary idempotent rerun preserves user content outside markers" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" --languages ts >/dev/null
  # Edit OUTSIDE the markers.
  printf '\n## My handwritten section\n\nSome notes I want to keep.\n' \
    >> "$REPO/docs/glossary.md"
  cp "$REPO/docs/glossary.md" "$TMP/before"

  # Add a new type and rerun.
  cat > "$REPO/more.ts" <<'EOF'
export interface Account {}
EOF
  cat > "$REPO/more-use.ts" <<'EOF'
import { Account } from './more'
export const a: Account = {} as Account
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m more )

  bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" --languages ts >/dev/null

  # User content survives.
  grep -q "My handwritten section" "$REPO/docs/glossary.md"
  grep -q "Some notes I want to keep" "$REPO/docs/glossary.md"
  # New term is in the auto block.
  grep -q "### Account" "$REPO/docs/glossary.md"
}

@test "scaffold-glossary refuses to mutate a marker-less glossary without --force-merge" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  mkdir -p "$REPO/docs"
  printf '# My Glossary\n\nNo markers here.\n' > "$REPO/docs/glossary.md"
  cp "$REPO/docs/glossary.md" "$TMP/before"

  out=$(bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" --languages ts 2>&1)
  diff -u "$TMP/before" "$REPO/docs/glossary.md"
  echo "$out" | grep -q "force-merge"
}

@test "scaffold-glossary --force-merge appends auto block to a marker-less glossary" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  mkdir -p "$REPO/docs"
  printf '# My Glossary\n' > "$REPO/docs/glossary.md"

  bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" --languages ts --force-merge >/dev/null
  grep -q "<!-- nyann:glossary:auto-start -->" "$REPO/docs/glossary.md"
  grep -q "My Glossary" "$REPO/docs/glossary.md"
  grep -q "### User" "$REPO/docs/glossary.md"
}

# --- schema validation ------------------------------------------------------

@test "scaffold-glossary --json output validates against schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages ts --json > "$TMP/draft.json"
  "${VALIDATE[@]}" --schemafile "${REPO_ROOT}/schemas/glossary-draft.schema.json" "$TMP/draft.json"
}

# --- regressions ------------------------------------------------------------

@test "scaffold-glossary survives a type with zero external references (set -e + pipefail)" {
  # Repo has exactly one exported type, only referenced inside its
  # defining file. The reference-count pipeline must tolerate
  # `git grep` returning rc 1 for no matches; without the explicit
  # `|| true` guard, set -e + pipefail aborts the whole script and
  # bootstrap/retrofit fail on any auto_populate=true profile applied
  # to a small / new codebase.
  cat > "$REPO/lonely.ts" <<'EOF'
export interface Lonely { x: string }
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  run bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" \
    --languages ts --json
  [ "$status" -eq 0 ]
  # Term has zero refs → drops out of selected. Counted as a candidate.
  [ "$(echo "$output" | jq '.total_candidates')" = "1" ]
  [ "$(echo "$output" | jq '.selected')" = "0" ]
  [ "$(echo "$output" | jq '.terms | length')" = "0" ]
}

@test "scaffold-glossary auto picks up JavaScript on a JS-only repo" {
  cat > "$REPO/lib.js" <<'EOF'
export class Animal {}
export const inst = new Animal();
EOF
  cat > "$REPO/use.js" <<'EOF'
import { Animal } from './lib';
export const a = new Animal();
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  # Auto mode reads detect-stack.sh's primary_language. For a
  # plain JS repo that's "javascript", which must include the js
  # scanner so non-empty candidates show up without manual override.
  run bash "${REPO_ROOT}/bin/scaffold-glossary.sh" --target "$REPO" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.languages[] | select(. == "js")] | length')" = "1" ]
  [ "$(echo "$output" | jq '[.terms[] | select(.name == "Animal")] | length')" = "1" ]
}

# --- profile gating via scaffold-docs --------------------------------------

@test "scaffold-docs without --auto-glossary does NOT call scaffold-glossary" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  # Hand-roll a doc plan that scaffolds glossary as a local target.
  cat > "$TMP/doc-plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "glossary":     {"type": "local", "path": "docs/glossary.md"},
    "memory":       {"type": "local", "path": "memory"}
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null
}
JSON
  bash "${REPO_ROOT}/bin/scaffold-docs.sh" --plan "$TMP/doc-plan.json" --target "$REPO" >/dev/null
  # Glossary template is in place but the auto block is empty —
  # specifically, no detected term H3s appear inside the markers.
  [ -f "$REPO/docs/glossary.md" ]
  ! grep -q "### User" "$REPO/docs/glossary.md"
}

@test "scaffold-docs --auto-glossary populates the auto block" {
  cat > "$REPO/types.ts" <<'EOF'
export interface User {}
EOF
  cat > "$REPO/use.ts" <<'EOF'
import { User } from './types'
export const u: User = {} as User
EOF
  ( cd "$REPO" && git add . && git -c user.email=t@t -c user.name=t commit -q -m seed )

  cat > "$TMP/doc-plan.json" <<'JSON'
{
  "storage_strategy": "local",
  "targets": {
    "glossary":     {"type": "local", "path": "docs/glossary.md"},
    "memory":       {"type": "local", "path": "memory"}
  },
  "claude_md_mode": "router",
  "size_budget_kb": 3,
  "staleness_days": null
}
JSON
  bash "${REPO_ROOT}/bin/scaffold-docs.sh" --plan "$TMP/doc-plan.json" --target "$REPO" \
    --auto-glossary --glossary-languages ts >/dev/null
  grep -q "### User" "$REPO/docs/glossary.md"
}
