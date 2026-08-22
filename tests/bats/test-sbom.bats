#!/usr/bin/env bats
# SBOM generation (security.sbom): the gen-ci sbom.yml workflow emission
# and the release-time SBOM asset attachment in github-release.sh. syft
# and gh are PATH mocks; nothing touches the network.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GEN="${REPO_ROOT}/bin/gen-ci.sh"
  GHREL="${REPO_ROOT}/bin/release/github-release.sh"
  TMP=$(mktemp -d -t nyann-sbom.XXXXXX)
  TMP="$(cd "$TMP" && pwd -P)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  PROFILE="$TMP/profile.json"
  STACK="$TMP/stack.json"
  cat > "$STACK" <<'JSON'
{ "primary_language": "typescript", "secondary_languages": [], "is_monorepo": false }
JSON

  GH_LOG="$TMP/gh.log"
  SYFT_LOG="$TMP/syft.log"
  export GH_LOG SYFT_LOG
  MOCK="$TMP/mock"
  mkdir -p "$MOCK"
  cat > "$MOCK/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status")     exit 0 ;;
  "release create")  echo "https://github.com/o/r/releases/tag/$3"; exit 0 ;;
  "release upload")  exit "${GH_UPLOAD_RC:-0}" ;;
esac
exit 0
SH
  cat > "$MOCK/syft" <<'SH'
#!/usr/bin/env bash
printf 'syft %s\n' "$*" >> "$SYFT_LOG"
# args: dir:<path> -o <fmt>=<outfile>
out="${3#*=}"
[ -n "$out" ] && echo '{"bomFormat":"stub"}' > "$out"
exit "${SYFT_RC:-0}"
SH
  chmod +x "$MOCK/gh" "$MOCK/syft"
}

teardown() { rm -rf "$TMP"; }

# make_profile [sbom-json] — the gen-ci base profile with an optional
# security.sbom block. Built with jq (NOT a heredoc with ${var:+...}:
# the alternate text of that expansion undergoes quote removal, which
# silently strips the JSON quoting).
make_profile() {
  local sbom="${1:-null}"
  jq -n --argjson sbom "$sbom" '{
    name: "test-profile",
    schemaVersion: 1,
    stack: { primary_language: "typescript", framework: null, package_manager: "npm" },
    branching: { strategy: "github-flow", base_branches: ["main"] },
    hooks: { pre_commit: [], commit_msg: ["conventional-commits"], pre_push: [] },
    extras: { gitignore: true, claude_md: true, github_actions_ci: true },
    conventions: { commit_format: "conventional-commits" },
    ci: { enabled: true, node_version: "20" }
  } + (if $sbom != null then { security: { sbom: $sbom } } else {} end)' > "$PROFILE"
}

run_gen() { bash "$GEN" --profile "$PROFILE" --stack "$STACK" --target "$REPO" "$@"; }

# --- gen-ci emission ---------------------------------------------------------

@test "sbom disabled / absent → no sbom.yml, no preview block" {
  make_profile
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "nyann:sbom:start"
  run_gen >/dev/null 2>&1
  [ ! -f "$REPO/.github/workflows/sbom.yml" ]
}

@test "sbom enabled → sbom.yml written inside markers with cyclonedx defaults" {
  make_profile '{"enabled": true}'
  run_gen >/dev/null 2>&1
  wf="$REPO/.github/workflows/sbom.yml"
  [ -f "$wf" ]
  grep -q "# nyann:sbom:start" "$wf"
  grep -q "# nyann:sbom:end" "$wf"
  grep -q "format: cyclonedx-json" "$wf"
  grep -q "output-file: sbom.cyclonedx.json" "$wf"
  grep -q "branches: \[main\]" "$wf"
}

@test "sbom format spdx toggles the action format and filename" {
  make_profile '{"enabled": true, "format": "spdx"}'
  run_gen >/dev/null 2>&1
  wf="$REPO/.github/workflows/sbom.yml"
  grep -q "format: spdx-json" "$wf"
  grep -q "output-file: sbom.spdx.json" "$wf"
}

@test "sbom workflow actions are SHA-pinned with version comments" {
  make_profile '{"enabled": true}'
  run_gen >/dev/null 2>&1
  wf="$REPO/.github/workflows/sbom.yml"
  grep -Eq 'uses: actions/checkout@[0-9a-f]{40} # v' "$wf"
  grep -Eq 'uses: anchore/sbom-action@[0-9a-f]{40} # v' "$wf"
}

@test "sbom emission is idempotent and preserves content outside markers" {
  make_profile '{"enabled": true}'
  run_gen >/dev/null 2>&1
  wf="$REPO/.github/workflows/sbom.yml"
  first=$(cat "$wf")
  printf '\n# user note kept\n' >> "$wf"
  run_gen >/dev/null 2>&1
  grep -q "# user note kept" "$wf"
  # Exactly one marker LINE (the template's header prose also mentions the
  # marker string, so count exact-line matches), and the regenerated
  # region is byte-identical to the first write.
  [ "$(grep -cx "# nyann:sbom:start" "$wf")" -eq 1 ]
  [ "$(grep -cx "# nyann:sbom:end" "$wf")" -eq 1 ]
  eline=$(grep -nx "# nyann:sbom:end" "$wf" | cut -d: -f1)
  [ "$(head -n "$eline" "$wf")" = "$first" ]
}

@test "dry-run previews the sbom block without writing" {
  make_profile '{"enabled": true}'
  run run_gen --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "nyann:sbom:start"
  [ ! -d "$REPO/.github" ]
}

# --- release-time attachment -------------------------------------------------

rel() { # extra github-release args
  PATH="$MOCK:$PATH" bash "$GHREL" --tag v9.9.9 --gh "$MOCK/gh" --syft "$MOCK/syft" \
    --target "$REPO" "$@" 2>/dev/null
}

@test "release attaches the SBOM asset when enabled and syft is present" {
  make_profile '{"enabled": true, "attach_to_release": true}'
  out=$(rel --profile "$PROFILE")
  [ "$(echo "$out" | jq -r '.outcome')" = "created" ]
  [ "$(echo "$out" | jq -r '.sbom.outcome')" = "attached" ]
  [ "$(echo "$out" | jq -r '.sbom.asset')" = "sbom.cyclonedx.json" ]
  grep -q "dir:$REPO" "$SYFT_LOG"
  grep -q "release upload v9.9.9" "$GH_LOG"
}

@test "spdx format flows through to the release asset" {
  make_profile '{"enabled": true, "format": "spdx"}'
  out=$(rel --profile "$PROFILE")
  [ "$(echo "$out" | jq -r '.sbom.asset')" = "sbom.spdx.json" ]
  grep -q "spdx-json=" "$SYFT_LOG"
}

@test "attach_to_release false → no syft run, sbom outcome disabled" {
  make_profile '{"enabled": true, "attach_to_release": false}'
  out=$(rel --profile "$PROFILE")
  [ "$(echo "$out" | jq -r '.outcome')" = "created" ]
  [ "$(echo "$out" | jq -r '.sbom.outcome')" = "disabled" ]
  [ ! -f "$SYFT_LOG" ]
}

@test "syft absent → soft-skip with a next_steps hint, release still created" {
  make_profile '{"enabled": true}'
  out=$(PATH="$MOCK:$PATH" bash "$GHREL" --tag v9.9.9 --gh "$MOCK/gh" \
    --syft "$TMP/no-such-syft" --target "$REPO" --profile "$PROFILE" 2>/dev/null)
  [ "$(echo "$out" | jq -r '.outcome')" = "created" ]
  [ "$(echo "$out" | jq -r '.sbom.outcome')" = "skipped" ]
  [ "$(echo "$out" | jq -r '.sbom.skipped_reason')" = "syft-not-installed" ]
  echo "$out" | jq -r '.next_steps[]' | grep -q "syft"
}

@test "upload failure never fails the release (sbom outcome failed, exit 0)" {
  make_profile '{"enabled": true}'
  GH_UPLOAD_RC=1
  export GH_UPLOAD_RC
  run bash -c 'PATH="$1:$PATH" bash "$2" --tag v9.9.9 --gh "$1/gh" --syft "$1/syft" --target "$3" --profile "$4" 2>/dev/null' _ "$MOCK" "$GHREL" "$REPO" "$PROFILE"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.sbom.outcome')" = "failed" ]
}

@test "no profile → sbom outcome disabled (backwards-compatible output)" {
  out=$(rel)
  [ "$(echo "$out" | jq -r '.outcome')" = "created" ]
  [ "$(echo "$out" | jq -r '.sbom.outcome')" = "disabled" ]
}
