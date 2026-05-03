#!/usr/bin/env bash
# release.sh — cut a release: generate CHANGELOG from conventional commits,
# create a release commit + annotated tag.
#
# Usage:
#   release.sh --target <repo> --version <x.y.z>
#              [--strategy conventional-changelog|manual|changesets|release-please]
#              [--changelog <path>]         # default: CHANGELOG.md
#              [--tag-prefix <prefix>]      # default: v
#              [--from <ref>]               # default: latest tag matching prefix
#              [--push]                     # also push tag to origin
#              [--dry-run]                  # print what would happen, mutate nothing
#              [--wait-for-checks]          # gate the tag step on green CI for HEAD's PR
#              [--wait-for-checks-timeout <sec>]  # default 1800
#              [--wait-for-checks-interval <sec>] # default 30
#              [--allow-no-pr]              # allow --wait-for-checks when no PR matches HEAD (off by default)
#              [--allow-no-checks]          # allow --wait-for-checks when PR has no checks attached (off by default)
#              [--gh <path>]                # gh binary, default `gh`
#
# Output (JSON on stdout):
#   {
#     "status":    "released" | "skipped" | "noop",
#     "strategy":  "...",
#     "version":   "x.y.z",
#     "tag":       "vx.y.z",
#     "from":      "vx.y.(z-1)",
#     "commits":   [{sha, type, scope, subject}],
#     "changelog": "<rendered block>",
#     "pushed":    true|false
#   }
#
# Strategies:
#   - conventional-changelog: full flow (group commits, write CHANGELOG,
#     release commit, annotated tag). Handles the common case.
#   - manual: just annotated tag at HEAD; no CHANGELOG work.
#   - changesets / release-please: soft-skip with a note — those are
#     separate tool ecosystems nyann doesn't duplicate.
#
# Exit codes:
#   0 — released, skipped (soft), or noop
#   2 — hard error (bad version, not a git repo, dirty tree, invalid strategy)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
version=""
strategy="conventional-changelog"
changelog_path="CHANGELOG.md"
tag_prefix="v"
from_ref=""
push=false
dry_run=false
confirm=false
wait_for_checks=false
wait_timeout=1800
wait_interval=30
allow_no_pr=false
allow_no_checks=false
gh_bin="gh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         target="${2:-}"; shift 2 ;;
    --target=*)       target="${1#--target=}"; shift ;;
    --version)        version="${2:-}"; shift 2 ;;
    --version=*)      version="${1#--version=}"; shift ;;
    --strategy)       strategy="${2:-}"; shift 2 ;;
    --strategy=*)     strategy="${1#--strategy=}"; shift ;;
    --changelog)      changelog_path="${2:-}"; shift 2 ;;
    --changelog=*)    changelog_path="${1#--changelog=}"; shift ;;
    --tag-prefix)     tag_prefix="${2:-}"; shift 2 ;;
    --tag-prefix=*)   tag_prefix="${1#--tag-prefix=}"; shift ;;
    --from)           from_ref="${2:-}"; shift 2 ;;
    --from=*)         from_ref="${1#--from=}"; shift ;;
    --push)           push=true; shift ;;
    --dry-run)        dry_run=true; shift ;;
    --yes)            confirm=true; shift ;;
    --wait-for-checks)         wait_for_checks=true; shift ;;
    --wait-for-checks-timeout) wait_timeout="${2:-}"; shift 2 ;;
    --wait-for-checks-timeout=*) wait_timeout="${1#--wait-for-checks-timeout=}"; shift ;;
    --wait-for-checks-interval) wait_interval="${2:-}"; shift 2 ;;
    --wait-for-checks-interval=*) wait_interval="${1#--wait-for-checks-interval=}"; shift ;;
    --allow-no-pr)    allow_no_pr=true; shift ;;
    --allow-no-checks) allow_no_checks=true; shift ;;
    --gh)             gh_bin="${2:-}"; shift 2 ;;
    --gh=*)           gh_bin="${1#--gh=}"; shift ;;
    -h|--help)        sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

if $wait_for_checks; then
  [[ "$wait_timeout" =~ ^[0-9]+$ && "$wait_timeout" -ge 1 ]]   || nyann::die "--wait-for-checks-timeout must be a positive integer"
  [[ "$wait_interval" =~ ^[0-9]+$ && "$wait_interval" -ge 1 ]] || nyann::die "--wait-for-checks-interval must be a positive integer"
fi

# --- validate inputs ---------------------------------------------------------

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo"

[[ -n "$version" ]] || nyann::die "--version <x.y.z> is required"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  nyann::die "--version must be semver (x.y.z or x.y.z-prerelease): got '$version'"
fi

# Detect SemVer pre-release suffix (anything after `-`). When present:
# * skip CHANGELOG `[Unreleased]` promotion — those entries are still
#   queued for the eventual stable release; a -rc.1 cut shouldn't
#   collapse them into a permanent section.
# * mark the GitHub release as prerelease in the output JSON
#   (downstream consumers can branch on this to flip --prerelease on
#   `gh release create`).
is_prerelease=false
if [[ "$version" == *-* ]]; then
  is_prerelease=true
fi

case "$strategy" in
  conventional-changelog|manual|changesets|release-please) ;;
  *) nyann::die "--strategy must be conventional-changelog|manual|changesets|release-please" ;;
esac

if [[ -n "$tag_prefix" ]] && ! [[ "$tag_prefix" =~ ^[A-Za-z0-9._/-]*$ ]]; then
  nyann::die "--tag-prefix must contain only [A-Za-z0-9._/-]: got '$tag_prefix'"
fi

# --changelog must stay inside the repo. Without this, `release.sh
# --changelog ../../.zshrc --version 1.2.3 --yes` writes outside the
# target and then `git add` fails — but the external file is already
# modified by that point.
if [[ "$changelog_path" == /* || "$changelog_path" == *".."* ]]; then
  nyann::die "--changelog path must be repo-relative and cannot contain '..': got '$changelog_path'"
fi
nyann::assert_path_under_target "$target" "$target/$changelog_path" "--changelog" >/dev/null

if [[ -n "$from_ref" ]] && ! nyann::valid_git_ref "$from_ref"; then
  nyann::die "--from must be a valid git ref: got '$from_ref'"
fi

tag="${tag_prefix}${version}"
tmp_changelog=""
push_err=""
commits_tsv=""
trap 'rm -f "$tmp_changelog" "$push_err" ${commits_tsv:+"$commits_tsv"}' EXIT

# --- soft-skip paths ---------------------------------------------------------

skip() {
  jq -n --arg reason "$1" --arg strategy "$strategy" --arg version "$version" --arg tag "$tag" \
    '{status:"skipped", strategy:$strategy, version:$version, tag:$tag, reason:$reason}'
  exit 0
}

case "$strategy" in
  changesets)
    skip "use the changesets CLI directly — nyann does not duplicate it"
    ;;
  release-please)
    skip "release-please runs as a GitHub Action — nyann does not duplicate it"
    ;;
esac

# --- tag existence + clean tree ---------------------------------------------

if git -C "$target" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  nyann::die "tag $tag already exists"
fi

if ! $dry_run; then
  if ! git -C "$target" diff --quiet || ! git -C "$target" diff --cached --quiet; then
    nyann::die "working tree has uncommitted changes; commit or stash first"
  fi
fi

# --- resolve from-ref --------------------------------------------------------
# When --from isn't passed, pick the latest tag matching tag_prefix. When no
# prior tag exists, default to the root commit.

if [[ -z "$from_ref" ]]; then
  latest_tag=$(git -C "$target" tag --list "${tag_prefix}*" --sort=-v:refname | head -n1)
  if [[ -n "$latest_tag" ]]; then
    from_ref="$latest_tag"
    log_range="${from_ref}..HEAD"
  else
    from_ref="$(git -C "$target" rev-list --max-parents=0 HEAD | head -n1)"
    # First release: include the root commit itself. `root..HEAD`
    # excludes the root commit, which turns a one-commit repo into a
    # false noop and drops the initial commit from the changelog.
    log_range="HEAD"
  fi
fi

if [[ -n "$from_ref" ]] && ! nyann::valid_git_ref "$from_ref"; then
  nyann::die "resolved from-ref is not a valid git ref: $from_ref"
fi

if [[ -z "${log_range:-}" ]]; then
  log_range="${from_ref}..HEAD"
fi

# --- collect commits in range ------------------------------------------------

# Accumulate parsed commits as TSV; one trailing jq turns it into the
# commits_json array. This replaces the per-commit `jq '. + [{...}]'`
# fork (one per commit on the release range — 50 commits = 50 forks).
commits_tsv=$(mktemp -t nyann-release-commits.XXXXXX)
# Assign the regex to a variable — bash's parser gets confused by embedded
# parens when the pattern is inlined on the `=~` RHS.
cc_regex='^([a-z]+)(\([^)]+\))?(!?):[[:space:]](.*)$'
while IFS= read -r sha && IFS= read -r subject; do
  [[ -z "$sha" ]] && continue
  # Parse Conventional Commits: type(scope)?: subject — with ! for breaking.
  ctype=""; cscope=""; csubject="$subject"; breaking=false
  if [[ "$subject" =~ $cc_regex ]]; then
    ctype="${BASH_REMATCH[1]}"
    cscope="${BASH_REMATCH[2]}"
    cscope="${cscope#(}"
    cscope="${cscope%)}"
    [[ "${BASH_REMATCH[3]}" == "!" ]] && breaking=true
    csubject="${BASH_REMATCH[4]}"
  fi
  # Subject may legitimately contain tabs; replace with a single space
  # before serialising so the TSV stays parseable. Conventional Commit
  # subjects are single-line by spec, so newlines are not a concern here.
  csubject_safe="${csubject//$'\t'/ }"
  printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$ctype" "$cscope" "$csubject_safe" "$breaking" >> "$commits_tsv"
done < <(git -C "$target" log --pretty=tformat:'%H%n%s' "$log_range" 2>/dev/null || true)

commits_json=$(jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({sha:.[0], type:.[1], scope:.[2], subject:.[3], breaking:(.[4] == "true")})
' < "$commits_tsv")

n_commits=$(jq 'length' <<<"$commits_json")
if (( n_commits == 0 )) && [[ "$strategy" == "conventional-changelog" ]]; then
  jq -n --arg strategy "$strategy" --arg version "$version" --arg tag "$tag" --arg from "$from_ref" \
    '{status:"noop", strategy:$strategy, version:$version, tag:$tag, from:$from, reason:"no commits since $from"}'
  exit 0
fi

# --- render changelog block (conventional-changelog only) --------------------

render_changelog_block() {
  local date_str
  date_str=$(date +%Y-%m-%d)
  # Single jq program renders the whole block: header, breaking section,
  # nine canonical type sections in stable order, then "Other" for the
  # leftovers. Replaces ~12 separate jq invocations (one per section
  # + a `jq -R | jq -s | jq -c` chain to build the canonical list) and
  # ~12 reparses of $commits_json over the same input.
  jq -r --arg version "$version" --arg date "$date_str" '
    def fmt_entry: "- " + (if .scope != "" then "**" + .scope + "**: " else "" end) + .subject + " (" + (.sha[0:7]) + ")";
    def section($heading; $entries):
      if ($entries | length) == 0 then ""
      else "### " + $heading + "\n\n" + ([$entries[] | fmt_entry] | join("\n")) + "\n\n"
      end;
    ["feat","fix","perf","refactor","docs","test","build","ci","chore"] as $known |
    "## [" + $version + "] — " + $date + "\n\n" +
    section("⚠️ Breaking changes"; [.[] | select(.breaking == true)]) +
    section("Features";    [.[] | select(.breaking == false and .type == "feat")]) +
    section("Fixes";       [.[] | select(.breaking == false and .type == "fix")]) +
    section("Performance"; [.[] | select(.breaking == false and .type == "perf")]) +
    section("Refactors";   [.[] | select(.breaking == false and .type == "refactor")]) +
    section("Docs";        [.[] | select(.breaking == false and .type == "docs")]) +
    section("Tests";       [.[] | select(.breaking == false and .type == "test")]) +
    section("Build";       [.[] | select(.breaking == false and .type == "build")]) +
    section("CI";          [.[] | select(.breaking == false and .type == "ci")]) +
    section("Chores";      [.[] | select(.breaking == false and .type == "chore")]) +
    section("Other";       [.[] | select(.breaking == false and (([.type] | inside($known)) | not))])
  ' <<<"$commits_json"
}

changelog_block=""
if [[ "$strategy" == "conventional-changelog" ]]; then
  changelog_block=$(render_changelog_block)
fi

# --- mutation phase ----------------------------------------------------------

pushed=false
if $dry_run; then
  # Conform to ReleaseSuccess in schemas/release-result.schema.json:
  # next_steps[] is required (empty when nothing failed), and dry_run
  # is the optional discriminator that tells consumers no side-effects
  # ran. Schema validation of dry-run output is locked by bats.
  # Note: --wait-for-checks is intentionally NOT honored on --dry-run
  # so a "show me the plan" invocation can never burn 30 minutes
  # polling CI. The ci_gate field is omitted on dry-run output.
  jq -n \
    --arg status "released" \
    --arg strategy "$strategy" \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg from "$from_ref" \
    --arg changelog "$changelog_block" \
    --argjson commits "$commits_json" \
    --argjson pushed "$pushed" \
    --argjson prerelease "$is_prerelease" \
    '{status:$status, strategy:$strategy, version:$version, tag:$tag, from:$from,
      commits:$commits, changelog:$changelog, pushed:$pushed, next_steps:[],
      prerelease:$prerelease, dry_run:true}'
  exit 0
fi

# --- CI gate (--wait-for-checks) -------------------------------------------
# When --wait-for-checks is set, find the PR associated with HEAD and
# block on bin/wait-for-pr-checks.sh until the checks settle. Tag is
# only created if checks pass / no checks attached / no PR found.
# Hard-fail on fail / timeout / unreachable-gh — the user opted into
# the gate, so silently proceeding would defeat the purpose.

ci_gate_json=""
if $wait_for_checks; then
  # gh availability is non-negotiable: the user explicitly asked us
  # to gate on CI; if we can't talk to gh we cannot gate. Unlike the
  # other gh-touching scripts (which soft-skip), this is opt-in
  # gating so the failure mode is "die loudly", not "silently skip".
  if ! command -v "$gh_bin" >/dev/null 2>&1; then
    nyann::die "--wait-for-checks: gh binary not found at '$gh_bin' — install gh or unset --wait-for-checks"
  fi
  if ! "$gh_bin" auth status >/dev/null 2>&1; then
    nyann::die "--wait-for-checks: gh is not authenticated — run 'gh auth login' or unset --wait-for-checks"
  fi

  # Resolve the PR for HEAD via search. Works for both open and merged
  # PRs (search-by-SHA matches the PR's head + merge commit). When
  # HEAD landed via a merge commit on main, the merge commit's SHA
  # surfaces the merged PR.
  head_sha=$(git -C "$target" rev-parse HEAD)
  # Pipe through jq locally rather than `gh --jq` so the lookup works
  # against any gh version and our test mocks can stay JSON-only.
  pr_list_json=$("$gh_bin" pr list --search "$head_sha" --state all --limit 1 --json number 2>/dev/null || echo '[]')
  pr_num=$(jq -r '.[0].number // empty' <<<"$pr_list_json" 2>/dev/null || true)

  if [[ -z "$pr_num" ]]; then
    # No PR found for HEAD. Hard-fail by default so the gate is
    # meaningful — squash/rebase release flows where the release
    # commit's SHA doesn't map back to the PR would silently bypass
    # the check otherwise. Users cutting releases from local-only
    # commits or first-time releases can opt back in via --allow-no-pr.
    if $allow_no_pr; then
      nyann::warn "--wait-for-checks: no PR found for HEAD ($head_sha); proceeding because --allow-no-pr was set"
      ci_gate_json='{"outcome":"no-pr-found"}'
    else
      nyann::die "--wait-for-checks: no PR found for HEAD ($head_sha); refusing to tag without a verified CI signal. Re-run with --allow-no-pr to release anyway (legitimate for first-cut or local-only commits), or push your commit to a PR first."
    fi
  else
    checks_out=$("${_script_dir}/wait-for-pr-checks.sh" --target "$target" \
      --pr "$pr_num" --gh "$gh_bin" --timeout "$wait_timeout" --interval "$wait_interval" 2>/dev/null) || true
    checks_outcome=$(jq -r '.outcome // "skipped"' <<<"$checks_out" 2>/dev/null || echo "skipped")
    case "$checks_outcome" in
      pass)
        nyann::log "--wait-for-checks: PR #$pr_num CI passed; proceeding with tag"
        ci_gate_json=$(jq -n --arg outcome "pass" --argjson pr "$pr_num" \
          '{outcome:$outcome, pr_number:$pr}')
        ;;
      no-checks)
        if $allow_no_checks; then
          nyann::warn "--wait-for-checks: no checks attached to PR #$pr_num — proceeding because --allow-no-checks was set"
          ci_gate_json=$(jq -n --argjson pr "$pr_num" '{outcome:"no-checks", pr_number:$pr}')
        else
          nyann::die "--wait-for-checks: no checks attached to PR #$pr_num — workflows may not have registered yet. Re-run with --allow-no-checks if the repo genuinely has no PR CI, or wait for workflows to attach and retry."
        fi
        ;;
      fail)
        nyann::die "--wait-for-checks: PR #$pr_num CI failed; tag not created (inspect via 'gh pr checks $pr_num')"
        ;;
      timeout)
        nyann::die "--wait-for-checks: PR #$pr_num CI did not settle within ${wait_timeout}s; tag not created (rerun with --wait-for-checks-timeout=<larger>)"
        ;;
      *)
        nyann::die "--wait-for-checks: could not poll PR #$pr_num CI (outcome=${checks_outcome}); tag not created"
        ;;
    esac
  fi
fi

case "$strategy" in
  conventional-changelog)
    # CHANGELOG writes are user-visible content mutations; require
    # --yes (or --dry-run, which exited above) so a caller cannot
    # inadvertently overwrite CHANGELOG.md without having seen the
    # rendered block first. The release skill runs --dry-run, shows
    # the changelog block to the user, then re-invokes with --yes.
    if ! $confirm; then
      {
        printf 'release.sh: preview-before-mutate — rendered CHANGELOG block:\n\n'
        printf '%s\n\n' "$changelog_block"
        if $is_prerelease; then
          printf '(prerelease detected: %s — CHANGELOG will NOT be modified, the [Unreleased] section stays queued for the eventual stable release; only the tag is created.)\n\n' "$version"
        fi
        printf 'Re-run with --yes to write to %s and create the release commit.\n' "$changelog_path"
        printf '(Or re-run with --dry-run to see the full JSON plan first.)\n'
      } >&2
      exit 2
    fi

    if $is_prerelease; then
      # Prerelease: do NOT touch CHANGELOG and do NOT make a release
      # commit. The tag (added below the case) is enough for `gh
      # release create --prerelease` consumers. The [Unreleased]
      # section stays queued for the stable cut.
      :
    else
      # Prepend changelog_block to CHANGELOG. Atomic: assemble into tmp,
      # then `mv` into place so a mid-write crash can't lose user content.
      full_changelog="$target/$changelog_path"
      [[ -L "$full_changelog" ]] && nyann::die "refusing to write CHANGELOG via symlink: $full_changelog"
      tmp_changelog=$(mktemp -t nyann-changelog.XXXXXX)
      if [[ -f "$full_changelog" ]]; then
        existing=$(cat "$full_changelog")
        printf '%s\n%s' "$changelog_block" "$existing" > "$tmp_changelog"
      else
        {
          printf '# Changelog\n\n'
          printf 'All notable changes to this project are documented here. Format follows [Keep a Changelog](https://keepachangelog.com).\n\n'
          printf '%s' "$changelog_block"
        } > "$tmp_changelog"
      fi
      mv "$tmp_changelog" "$full_changelog"

      # Release commit runs under the repo's configured identity when
      # available; nyann@local is only the fallback.
      nyann::resolve_identity "$target"
      git -C "$target" add -- "$changelog_path"
      git -C "$target" \
        -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
        commit -q -m "chore(release): $tag" >/dev/null
    fi
    ;;
  manual)
    # No changelog work — tag at HEAD.
    ;;
esac

nyann::resolve_identity "$target"
git -C "$target" \
  -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
  tag -a -m "release $tag" -- "$tag"

# Track recovery steps so the JSON output can tell the caller exactly
# what's needed to finish a half-pushed release (tag pushed but branch
# failed, branch pushed but tag failed, neither pushed). The skill
# layer / CI surfaces these to the user; the exit code (set below)
# also flips non-zero when --push was requested but didn't fully land.
next_steps_json='[]'
add_next_step() {
  next_steps_json=$(jq --arg s "$1" '. + [$s]' <<<"$next_steps_json")
}

tag_pushed=false
branch_pushed=true   # only flips false when conventional-changelog branch push fails

if $push; then
  # Defensive git config on push: pin protocol allowlist + neutralise
  # any local hook a malicious origin URL might trigger via pre-push.
  # Symmetric with the team-source clone/fetch hardening.
  git_safe_push=(-c protocol.allow=user -c protocol.ext.allow=never \
                 -c protocol.file.allow=user \
                 -c core.hooksPath=/dev/null)

  push_err=$(mktemp -t nyann-release-push.XXXXXX)
  if ! git "${git_safe_push[@]}" -C "$target" push origin -- "$tag" 2>"$push_err"; then
    # Git's push failure output can include the remote URL (with
    # tokens). Redact before surfacing the warning.
    err=$(nyann::redact_url "$(cat "$push_err")")
    nyann::warn "push of tag $tag failed: $err"
    add_next_step "git push origin $tag   # tag created locally; re-push after fixing the cause above"
  else
    tag_pushed=true
  fi
  rm -f "$push_err"

  if [[ "$strategy" == "conventional-changelog" ]] && ! $is_prerelease; then
    # Prerelease cuts skip the CHANGELOG write entirely (see the
    # conventional-changelog branch above), so there's no release
    # commit to push — only the tag.
    # For real releases: also push the release commit to
    # origin/<current-branch> so CHANGELOG is visible upstream.
    # Best-effort: surface failures (auth, network, protected-branch
    # rejection) so the user notices the tag is published but the
    # branch hasn't caught up.
    cur=$(git -C "$target" branch --show-current 2>/dev/null || echo "")
    if [[ -n "$cur" ]]; then
      branch_push_err=$(mktemp -t nyann-release-branch-push.XXXXXX)
      if ! git "${git_safe_push[@]}" -C "$target" push origin -- "$cur" >/dev/null 2>"$branch_push_err"; then
        err=$(nyann::redact_url "$(cat "$branch_push_err")")
        nyann::warn "push of branch $cur failed (tag $tag still pushed): $err"
        add_next_step "git push origin $cur   # release commit is local-only; push after fixing the cause above"
        branch_pushed=false
      fi
      rm -f "$branch_push_err"
    fi
  fi
fi

# `pushed` aggregates BOTH the tag push and (for conventional-changelog)
# the branch push. False if any requested push step failed.
pushed=false
if $push && $tag_pushed && $branch_pushed; then
  pushed=true
fi

if [[ -n "$ci_gate_json" ]]; then
  jq -n \
    --arg status "released" \
    --arg strategy "$strategy" \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg from "$from_ref" \
    --arg changelog "$changelog_block" \
    --argjson commits "$commits_json" \
    --argjson pushed "$pushed" \
    --argjson next_steps "$next_steps_json" \
    --argjson prerelease "$is_prerelease" \
    --argjson ci_gate "$ci_gate_json" \
    '{status:$status, strategy:$strategy, version:$version, tag:$tag, from:$from,
      commits:$commits, changelog:$changelog, pushed:$pushed, next_steps:$next_steps,
      prerelease:$prerelease, ci_gate:$ci_gate}'
else
  jq -n \
    --arg status "released" \
    --arg strategy "$strategy" \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg from "$from_ref" \
    --arg changelog "$changelog_block" \
    --argjson commits "$commits_json" \
    --argjson pushed "$pushed" \
    --argjson next_steps "$next_steps_json" \
    --argjson prerelease "$is_prerelease" \
    '{status:$status, strategy:$strategy, version:$version, tag:$tag, from:$from,
      commits:$commits, changelog:$changelog, pushed:$pushed, next_steps:$next_steps,
      prerelease:$prerelease}'
fi

# Exit non-zero when --push was requested but at least one push step
# failed. Lets CI / skill-layer wrappers detect the half-state without
# having to parse the JSON; the next_steps array tells the user what
# to do next. Exit 0 when --push wasn't requested OR both pushes
# succeeded.
if $push && ! $pushed; then
  exit 3
fi
