#!/usr/bin/env bats
# bin/release.sh — the CI gate that --push enables by default.
#
# A pushed tag is consumed by the marketplace, so --push auto-enables the
# wait-for-checks gate when (a) origin is a GitHub remote and (b) gh is
# authenticated — degrading gracefully otherwise. --no-wait-for-checks opts out.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RELEASE="${REPO_ROOT}/bin/release.sh"
  TMP=$(mktemp -d)
}

teardown() { rm -rf "$TMP"; }

# Repo with conventional-commit history since v0.1.0.
make_repo() {
  local repo="$TMP/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: initial"
    git -c user.email=t@t -c user.name=t tag v0.1.0
    echo a > a.txt
    git -c user.email=t@t -c user.name=t add a.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat(api): add A"
  )
  echo "$repo"
}

# gh mock: auth ok, pr list/api return one PR matching HEAD, checks = $2.
mock_gh() {
  local checks_outcome="${1:-success}"
  local repo="$2"
  local head_sha; head_sha=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$TMP/mock"
  cat > "$TMP/mock/gh" <<SH
#!/bin/sh
case "\$1" in
  auth) exit 0 ;;
  api) echo '[{"number":7,"head":{"sha":"${head_sha}"}}]'; exit 0 ;;
  pr)
    case "\$2" in
      list) echo '[{"number":7,"headRefOid":"${head_sha}"}]'; exit 0 ;;
      checks)
        case "${checks_outcome}" in
          success) echo '[{"name":"lint","status":"completed","conclusion":"success","workflow":"ci.yml"}]' ;;
          failure) echo '[{"name":"test","status":"completed","conclusion":"failure","workflow":"ci.yml"}]' ;;
        esac
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$TMP/mock/gh"
  echo "$TMP/mock/gh"
}

@test "github origin + --push auto-enables the gate: failing CI blocks the tag" {
  repo=$(make_repo)
  git -C "$repo" remote add origin https://github.com/test/repo.git
  gh=$(mock_gh failure "$repo")
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push \
    --wait-for-checks-timeout 5 --wait-for-checks-interval 1 --gh "$gh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -F -e "CI failed"
  # gate fired before any mutation — no release tag was created
  ! git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "--no-wait-for-checks opts out: failing CI does NOT block (gate skipped)" {
  repo=$(make_repo)
  git -C "$repo" remote add origin https://github.com/test/repo.git
  gh=$(mock_gh failure "$repo")
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push \
    --no-wait-for-checks --gh "$gh"
  # Gate skipped, so no "CI failed". The push to the github URL fails (exit 3),
  # but the release commit + tag were created locally first.
  ! echo "$output" | grep -qF -e "CI failed"
  git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "non-github origin does NOT auto-enable the gate (push proceeds)" {
  repo=$(make_repo)
  bare="$TMP/bare.git"
  git init -q --bare "$bare"
  git -C "$repo" remote add origin "file://$bare"
  gh=$(mock_gh failure "$repo")  # would block IF the gate ran
  out=$(bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push --gh "$gh" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$(echo "$out" | jq -r 'has("ci_gate")')" = "false" ]
  git -C "$repo" ls-remote --tags origin | grep -F -e "v0.2.0"
}

@test "github origin + unauthenticated gh → warn and proceed (graceful degrade)" {
  repo=$(make_repo)
  git -C "$repo" remote add origin https://github.com/test/repo.git
  mkdir -p "$TMP/mock"
  printf '#!/bin/sh\ncase "$1" in auth) exit 1 ;; *) exit 0 ;; esac\n' > "$TMP/mock/gh"
  chmod +x "$TMP/mock/gh"
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --yes --push --gh "$TMP/mock/gh"
  # Gate skipped (gh unauth) → warning emitted, no "CI failed", tag made locally.
  echo "$output" | grep -F -e "without a CI gate"
  git -C "$repo" rev-parse v0.2.0 >/dev/null 2>&1
}

@test "dry-run never enables the gate" {
  repo=$(make_repo)
  git -C "$repo" remote add origin https://github.com/test/repo.git
  gh=$(mock_gh failure "$repo")
  run bash "$RELEASE" --target "$repo" --version 0.2.0 --dry-run --push --gh "$gh"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF -e "CI failed"
}
