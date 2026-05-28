#!/usr/bin/env bats
# Dead code scan (P6).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMP="$(mktemp -d -t nyann-deadcode.XXXXXX)"
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

@test "JS: unused default import is flagged" {
  cat > "$REPO/a.js" <<'EOF'
import Foo from "x";
console.log("hello");
EOF
  ( cd "$REPO" && git add a.js )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings | length >= 1'
  echo "$out" | jq -e '.findings[] | select(.name == "Foo" and .kind == "unused-import")'
}

@test "JS: used import not flagged" {
  cat > "$REPO/b.js" <<'EOF'
import Foo from "x";
Foo();
EOF
  ( cd "$REPO" && git add b.js )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "JS: unused named import among used is flagged" {
  cat > "$REPO/c.js" <<'EOF'
import { Used, Unused } from "x";
Used();
EOF
  ( cd "$REPO" && git add c.js )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "Unused")'
  count=$(echo "$out" | jq '[.findings[] | select(.name == "Used")] | length')
  [ "$count" -eq 0 ]
}

@test "Python: unused import flagged" {
  cat > "$REPO/d.py" <<'EOF'
import os
print("nothing here")
EOF
  ( cd "$REPO" && git add d.py )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "os" and .rule == "python")'
}

@test "Python: used import not flagged" {
  cat > "$REPO/e.py" <<'EOF'
import os
print(os.getcwd())
EOF
  ( cd "$REPO" && git add e.py )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "Python: from M import A, B flags only the unused one" {
  cat > "$REPO/f.py" <<'EOF'
from typing import List, Dict
def g(x: List[int]) -> None: pass
EOF
  ( cd "$REPO" && git add f.py )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "Dict")'
  count=$(echo "$out" | jq '[.findings[] | select(.name == "List")] | length')
  [ "$count" -eq 0 ]
}

@test "Go: unused import in single-line form" {
  cat > "$REPO/g.go" <<'EOF'
package main
import "fmt"
func main() { println("hi") }
EOF
  ( cd "$REPO" && git add g.go )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "fmt")'
}

@test "Rust: unused use is flagged" {
  cat > "$REPO/h.rs" <<'EOF'
use std::collections::HashMap;
fn main() { println!("no map"); }
EOF
  ( cd "$REPO" && git add h.rs )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "HashMap")'
}

@test "TS: import type Foo from x captures Foo, not type" {
  cat > "$REPO/td.ts" <<'EOF'
import type Foo from "x";
const x: Foo = null as any;
EOF
  ( cd "$REPO" && git add td.ts )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  # Foo is used → not flagged. `type` keyword must never be reported.
  count_type=$(echo "$out" | jq '[.findings[] | select(.name == "type")] | length')
  count_foo=$(echo "$out" | jq '[.findings[] | select(.name == "Foo")] | length')
  [ "$count_type" -eq 0 ]
  [ "$count_foo" -eq 0 ]
}

@test "TS: import type Unused from x is flagged (Unused, not type)" {
  cat > "$REPO/td2.ts" <<'EOF'
import type Unused from "x";
const x = 1;
EOF
  ( cd "$REPO" && git add td2.ts )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "Unused")'
  count_type=$(echo "$out" | jq '[.findings[] | select(.name == "type")] | length')
  [ "$count_type" -eq 0 ]
}

@test "Python: import with trailing comment is still scanned (noqa)" {
  cat > "$REPO/noq.py" <<'EOF'
import os  # noqa: F401
print("nothing here")
EOF
  ( cd "$REPO" && git add noq.py )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "os" and .rule == "python")'
}

@test "Python: import with type: ignore comment is scanned" {
  cat > "$REPO/ti.py" <<'EOF'
import sys  # type: ignore
print("nothing here")
EOF
  ( cd "$REPO" && git add ti.py )
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.findings[] | select(.name == "sys" and .rule == "python")'
}

@test "Non-staged file not scanned (staged-only default)" {
  cat > "$REPO/i.js" <<'EOF'
import Unused from "x";
EOF
  # Don't stage.
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  count=$(echo "$out" | jq '.findings | length')
  [ "$count" -eq 0 ]
}

@test "Empty staged set produces empty findings array" {
  out=$(bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO")
  echo "$out" | jq -e '.summary.total == 0'
  echo "$out" | jq -e '.findings == []'
}

@test "Output validates against dead-code-scan schema" {
  if ! command -v uvx >/dev/null 2>&1 && ! command -v check-jsonschema >/dev/null 2>&1; then
    skip "no schema validator"
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    VALIDATE=(check-jsonschema)
  else
    VALIDATE=(uvx --quiet check-jsonschema)
  fi
  cat > "$REPO/z.js" <<'EOF'
import Foo from "x";
EOF
  ( cd "$REPO" && git add z.js )
  bash "$REPO_ROOT/bin/dead-code-scan.sh" --target "$REPO" > "$TMP/r.json"
  "${VALIDATE[@]}" --schemafile "$REPO_ROOT/schemas/dead-code-scan.schema.json" "$TMP/r.json"
}
