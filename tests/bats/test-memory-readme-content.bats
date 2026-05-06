#!/usr/bin/env bats
# templates/memory/README.tmpl positions memory/ as the ephemeral
# scratch layer, distinct from Claude Code's per-user auto-memory and
# from Project Memory (docs/). Per the v1.6.0 memory framing fix,
# the template MUST mention both reference points so users do not
# conflate the three layers.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TMPL="${REPO_ROOT}/templates/memory/README.tmpl"
}

@test "memory README template exists" {
  [ -f "$TMPL" ]
}

@test "template explicitly references Claude Code auto-memory location" {
  grep -q "~/.claude/projects" "$TMPL"
}

@test "template references Project Memory (docs/) as the durable layer" {
  grep -q "Project Memory" "$TMPL"
}

@test "template makes the layered model explicit" {
  grep -qi "ephemeral" "$TMPL"
  grep -qi "scratch" "$TMPL"
}

@test "template links to documentation principles doc" {
  grep -q "principles/documentation.md" "$TMPL"
}

@test "template no longer uses the misleading 'Session-scratch for Claude' framing" {
  ! grep -q "Session-scratch for Claude" "$TMPL"
}
