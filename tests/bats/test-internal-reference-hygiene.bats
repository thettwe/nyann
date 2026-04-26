#!/usr/bin/env bats
# Internal-reference hygiene lock.
# CLAUDE.md non-negotiable: "No internal references in code. Names must
# be self-descriptive. Traceability belongs in git history, not in the
# source." This test enforces it across every shipped artifact.
#
# Forbidden in shipped source / tests / docs (matched by the patterns
# in the @tests below):
#   * Capitalised audit-iteration labels
#   * Lower-case hyphenated audit-iteration labels
#   * "Pre-fix" / "Post-fix" historical-narrative comments tied to a
#     specific past PR
#   * Date-stamped audit-batch IDs
#
# Allowed (functional labels, not internal tracking):
#   * Step labels inside skill execution flows
#   * Algorithm-state names in two-phase commit / state-machine code
#   * "audit" as a product noun ("read-only audit" in doctor docs)

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # Exclude this lock file from its own grep so the @-test bodies
  # below (which legitimately contain the forbidden regexes as data)
  # don't trigger themselves.
  SELF="$(basename "${BATS_TEST_FILENAME}")"
}

@test "no audit-iteration references in shipped source / tests / docs" {
  cd "$REPO_ROOT"
  hits=$(grep -rnE '\b[Rr]ound[- ]?[0-9]+\b|\b[Pp]ost-[Rr]ound\b|\b[Pp]re-[Rr]ound\b|\b[Pp]re-fix\b|\b[Pp]ost-fix\b|\baudit-[0-9]{4}-[0-9]{2}-[0-9]{2}\b|\bRound[- ]?N\b' \
    --include='*.sh' --include='*.json' --include='*.md' --include='*.bats' --include='*.yml' --include='*.yaml' \
    bin/ schemas/ profiles/ templates/ hooks/ monitors/ skills/ commands/ tests/ docs/ \
    README.md CLAUDE.md CHANGELOG.md SECURITY.md CONTRIBUTING.md 2>/dev/null \
    | grep -vF "$SELF" || true)
  if [[ -n "$hits" ]]; then
    echo "Found internal-reference leakage:" >&2
    echo "$hits" >&2
    echo "" >&2
    echo "These violate CLAUDE.md's 'No internal references in code' rule." >&2
    echo "Replace each with a forward-looking WHY comment that doesn't" >&2
    echo "name a specific past iteration, batch, or fix attempt." >&2
    return 1
  fi
}

@test "no audit / review narrative phrasings in shipped docs" {
  cd "$REPO_ROOT"
  hits=$(grep -nE '\b(the audit said|the review said|the audit found|the review found|the audit flagged|the review flagged|the post-[Rr]ound)\b' \
    README.md CLAUDE.md CHANGELOG.md SECURITY.md CONTRIBUTING.md docs/*.md 2>/dev/null \
    | grep -vF "$SELF" || true)
  if [[ -n "$hits" ]]; then
    echo "Found audit/review narrative in shipped docs:" >&2
    echo "$hits" >&2
    return 1
  fi
}

@test "Phase labels are confined to skill flow + algorithm state names" {
  cd "$REPO_ROOT"
  # Phase numbers in skill bodies (under skills/) are Claude execution
  # flow steps; section dividers in gh-integration.sh use lower-case
  # ("phase 1: guard") so they fall outside this regex; the only
  # capitalised Phase usage in bin/ is the two-phase-commit pattern in
  # install-hooks.sh, which is allowlisted below.
  forbidden=$(grep -rnE '\bPhase [0-9A-D]\b' \
    --include='*.sh' --include='*.bats' --include='*.json' --include='*.yml' --include='*.yaml' \
    bin/ schemas/ profiles/ templates/ hooks/ monitors/ tests/ \
    2>/dev/null | grep -vF "$SELF" || true)
  unexpected=$(echo "$forbidden" | grep -vE 'bin/install-hooks\.sh:.*Phase [AB]' || true)
  if [[ -n "$unexpected" ]]; then
    echo "Found Phase labels outside skill flow + algorithm-state names:" >&2
    echo "$unexpected" >&2
    return 1
  fi
}
