#!/usr/bin/env bats
# bin/doctor.sh — IaC-drift sibling-probe integration.
#
# Doctor runs bin/iac-drift-scan.sh as a read-only probe (parallel to
# docs-drift), merges it as a top-level `iac_drift` field in --json output,
# renders an IAC DRIFT text section, and folds critical/high findings into the
# exit code (critical→5, high→4) without ever touching the numeric health
# score. These tests assert each of those wiring points.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOCTOR="${REPO_ROOT}/bin/doctor.sh"
  TMP="$(mktemp -d -t nyann-doctor-iac.XXXXXX)"
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

commit_all() { ( cd "$REPO" && git add -A && git commit -q -m fixture ); }

@test "doctor --json includes the iac_drift sibling field" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  commit_all
  out=$(bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  echo "$out" | jq -e 'has("iac_drift")' >/dev/null
  # The probe found the unpinned module ref (high).
  echo "$out" | jq -e '.iac_drift.summary.by_severity.high >= 1' >/dev/null
  echo "$out" | jq -e '[.iac_drift.findings[].kind] | index("unpinned-ref") != null' >/dev/null
}

@test "doctor (text mode) renders IAC DRIFT section when findings exist" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  commit_all
  out=$(bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --gh "$TMP/no-such-gh" 2>&1 || true)
  echo "$out" | grep -Fq "IAC DRIFT:"
}

@test "doctor exit code reflects a committed secret (critical → 5)" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  run bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --gh "$TMP/no-such-gh"
  # A committed secret is critical → doctor must escalate to 5 (never below).
  [ "$status" -eq 5 ]
}

@test "doctor JSON exit code escalates on iac critical too" {
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  # Capture stdout (JSON) separately from stderr (warns like "gh not found"),
  # which bats `run` would otherwise interleave and break jq.
  json=$(bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  echo "$json" | jq -e '.iac_drift.summary.by_severity.critical >= 1' >/dev/null
  # Exit code (via run) must escalate to 5 on the critical secret.
  run bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --json --gh "$TMP/no-such-gh"
  [ "$status" -eq 5 ]
}

@test "profile disabling iac.drift_check.enabled silences the probe" {
  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  cat > "$REPO/prod.tfvars" <<'EOF'
access_key = "AKIAIOSFODNN7EXAMPLE"
EOF
  commit_all
  # Author a local profile that resolves by path-equivalent: doctor takes a
  # bare name and resolves via load-profile.sh, so instead exercise the
  # scanner-level gate directly to prove the master switch reaches the probe.
  prof="$TMP/p.json"
  jq -n '{iac:{drift_check:{enabled:false}}}' > "$prof"
  out=$(bash "$REPO_ROOT/bin/iac-drift-scan.sh" --target "$REPO" --profile "$prof" 2>/dev/null)
  echo "$out" | jq -e '.summary.total == 0' >/dev/null
}

@test "iac_drift is score-isolated — health score unaffected by IaC findings" {
  # Two runs: one clean, one with an unpinned ref. The numeric health score
  # must be identical because compute-health-score reads only the DriftReport,
  # never iac_drift (same isolation contract as docs-drift). The IaC file is
  # added with a Conventional-Commits-compliant message so commit-history
  # compliance (which DOES feed the score) is held constant between runs.
  out_clean=$(bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  score_clean=$(echo "$out_clean" | jq -r '.health_score.score')

  cat > "$REPO/main.tf" <<'EOF'
module "vpc" { source = "git::https://github.com/org/mod.git?ref=main" }
EOF
  ( cd "$REPO" && git add -A && git commit -q -m "feat: add vpc module" )
  out_drift=$(bash "$DOCTOR" --target "$REPO" --profile terraform-monorepo --json --gh "$TMP/no-such-gh" 2>/dev/null || true)
  score_drift=$(echo "$out_drift" | jq -r '.health_score.score')

  # Sanity: the drift run actually surfaced the unpinned ref (so we're truly
  # comparing a clean vs. dirty IaC state, not two identical states).
  echo "$out_drift" | jq -e '.iac_drift.summary.total >= 1' >/dev/null
  [ "$score_clean" = "$score_drift" ]
}
