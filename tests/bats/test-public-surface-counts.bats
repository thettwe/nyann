#!/usr/bin/env bats
# Public-surface drift: lock the skill / command / profile / schema counts
# the README documents. When these change, the README + plugin manifest
# need to track. The assertions catch silent drift between docs and
# filesystem reality before it merges.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "skill count matches the documented number (30)" {
  count=$(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$count" = "30" ]
}

@test "every skill has a SKILL.md" {
  while IFS= read -r dir; do
    [ -f "$dir/SKILL.md" ] || { echo "missing SKILL.md in $dir" >&2; false; }
  done < <(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d)
}

@test "command file count matches the documented number (30 — one per skill)" {
  count=$(find "$REPO_ROOT/commands" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
  [ "$count" = "30" ]
}

@test "starter profile count matches the documented number (13)" {
  count=$(find "$REPO_ROOT/profiles" -maxdepth 1 -name '*.json' -type f -not -name '_schema.json' | wc -l | tr -d ' ')
  [ "$count" = "13" ]
}

@test "schema count matches the documented number (38)" {
  count=$(find "$REPO_ROOT/schemas" -maxdepth 1 -name '*.schema.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "38" ]
}

@test "every schema is documented in schemas/README.md" {
  for f in "$REPO_ROOT"/schemas/*.schema.json; do
    name=$(basename "$f")
    grep -Fq "$name" "$REPO_ROOT/schemas/README.md" \
      || { echo "schemas/README.md missing entry for $name" >&2; false; }
  done
}

@test "every profile validates against the schema" {
  for f in "$REPO_ROOT"/profiles/*.json; do
    [ "$(basename "$f")" = "_schema.json" ] && continue
    bash "$REPO_ROOT/bin/validate-profile.sh" "$f" >/dev/null 2>&1 \
      || { echo "profile failed validation: $f" >&2; false; }
  done
}
