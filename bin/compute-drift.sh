#!/usr/bin/env bash
# compute-drift.sh — compare a repo's actual state to a profile's expected
# state and emit a DriftReport JSON.
#
# Usage: compute-drift.sh --target <repo> --profile <path>
#
# Output: JSON DriftReport to stdout
#         (schemas/drift-report.schema.json).
#
# Readable summary can be rendered separately by retrofit.sh / doctor.sh.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
commit_scan=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --profile)       profile_path="${2:-}"; shift 2 ;;
    --profile=*)     profile_path="${1#--profile=}"; shift ;;
    --commit-scan)   commit_scan="${2:-20}"; shift 2 ;;
    --commit-scan=*) commit_scan="${1#--commit-scan=}"; shift ;;
    -h|--help)       sed -n '3,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
target="$(cd "$target" && pwd)"

# Validate the profile against the schema before consuming any field.
# bootstrap.sh and retrofit.sh already validate via load-profile.sh,
# but compute-drift can be invoked directly (tests, future skills,
# manual runs). Without this guard a hand-edited profile could ship
# `base_branches: ["--git-dir=/etc"]` and reach `git rev-parse` with a
# leading-dash arg parsed as an option (argument injection).
#
# Best-effort: when no JSON-schema validator is installed
# (check-jsonschema / uvx), fall back to a jq-empty parse check and
# warn — same pattern as gh-integration. A hard die here would break
# environments that previously ran compute-drift without `uv`.
if nyann::has_cmd check-jsonschema || nyann::has_cmd uvx; then
  if ! "${_script_dir}/validate-profile.sh" "$profile_path" >/dev/null 2>&1; then
    nyann::die "profile fails schema validation: $profile_path"
  fi
else
  jq empty "$profile_path" >/dev/null 2>&1 \
    || nyann::die "profile is not valid JSON: $profile_path"
  nyann::warn "no JSON-schema validator (check-jsonschema/uvx) installed; profile schema not enforced for $profile_path"
fi

profile_json="$(cat "$profile_path")"
profile_name=$(jq -r '.name' <<<"$profile_json")

missing_json='[]'
misconfigured_json='[]'
offenders_json='[]'

add_missing() {
  # $1=kind $2=path $3=detail
  missing_json=$(jq --arg kind "$1" --arg path "$2" --arg detail "${3:-}" '
    . + [{ kind: $kind, path: $path } + ( if $detail != "" then { detail: $detail } else {} end )]
  ' <<<"$missing_json")
}

add_misconfigured() {
  # $1=path $2=reason $3=csv missing_entries (optional)
  local csv="${3:-}"
  if [[ -n "$csv" ]]; then
    local arr=()
    IFS=',' read -ra arr <<<"$csv"
    local arr_json
    arr_json=$(printf '%s\n' "${arr[@]}" | jq -R . | jq -s .)
    misconfigured_json=$(jq --arg path "$1" --arg reason "$2" --argjson entries "$arr_json" '
      . + [{ path: $path, reason: $reason, missing_entries: $entries }]
    ' <<<"$misconfigured_json")
  else
    misconfigured_json=$(jq --arg path "$1" --arg reason "$2" '
      . + [{ path: $path, reason: $reason }]
    ' <<<"$misconfigured_json")
  fi
}

# --- MISSING: expected files from profile.extras + hooks + docs --------------

if [[ "$(jq -r '.extras.gitignore // false' <<<"$profile_json")" == "true" ]]; then
  [[ -f "$target/.gitignore" ]] || add_missing "gitignore" ".gitignore" "profile.extras.gitignore=true but no .gitignore present"
fi
if [[ "$(jq -r '.extras.claude_md // false' <<<"$profile_json")" == "true" ]]; then
  [[ -f "$target/CLAUDE.md" ]] || add_missing "claude-md" "CLAUDE.md" "profile.extras.claude_md=true"
fi
if [[ "$(jq -r '.extras.editorconfig // false' <<<"$profile_json")" == "true" ]]; then
  [[ -f "$target/.editorconfig" ]] || add_missing "editorconfig" ".editorconfig" ""
fi

# Hook files: presence of eslint/prettier/commitlint in profile.hooks
# implies Husky setup; presence of ruff/commitizen implies pre-commit.com.
# Check for the managed hook files we write.
hook_list=$(jq -r '[(.hooks.pre_commit // [])[], (.hooks.commit_msg // [])[]] | join(" ")' <<<"$profile_json")
case "$hook_list" in
  *eslint*|*prettier*|*commitlint*)
    [[ -f "$target/.husky/pre-commit" ]] || add_missing "husky-hook" ".husky/pre-commit" "JS/TS profile expects husky pre-commit"
    [[ -f "$target/.husky/commit-msg" ]] || add_missing "husky-hook" ".husky/commit-msg" "JS/TS profile expects husky commit-msg"
    [[ -f "$target/commitlint.config.js" ]] || add_missing "commitlint" "commitlint.config.js" ""
    ;;
esac
case "$hook_list" in
  *ruff*|*commitizen*|*black*|*mypy*)
    [[ -f "$target/.pre-commit-config.yaml" ]] || add_missing "pre-commit-config" ".pre-commit-config.yaml" "Python profile expects pre-commit.com config"
    ;;
esac
# The core commit-msg / block-main / gitleaks apply regardless.
case "$hook_list" in
  *block-main*)
    if [[ ! -f "$target/.husky/pre-commit" && ! -f "$target/.pre-commit-config.yaml" && ! -f "$target/.git/hooks/pre-commit" ]]; then
      add_missing "core-hook" ".git/hooks/pre-commit" "no hook framework installed"
    fi
    ;;
esac

# Doc scaffolding: check documentation.scaffold_types.
# Use `while read` rather than `for t in $(jq …)` so values containing
# whitespace (or IFS-sensitive characters from team-sourced profiles)
# don't word-split.
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  case "$t" in
    architecture) [[ -f "$target/docs/architecture.md" ]] || add_missing "doc" "docs/architecture.md" "profile scaffolds architecture" ;;
    prd)          [[ -f "$target/docs/prd.md" ]]          || add_missing "doc" "docs/prd.md" "profile scaffolds prd" ;;
    adrs)         [[ -f "$target/docs/decisions/ADR-000-record-architecture-decisions.md" ]] || add_missing "doc" "docs/decisions/ADR-000-record-architecture-decisions.md" "profile scaffolds ADRs" ;;
    research)     [[ -d "$target/docs/research" ]]        || add_missing "doc" "docs/research" "profile scaffolds research" ;;
  esac
done < <(jq -r '.documentation.scaffold_types[]?' <<<"$profile_json")

# CI workflow: detect missing .github/workflows/ci.yml when profile.ci.enabled=true
if [[ "$(jq -r '.ci.enabled // false' <<<"$profile_json")" == "true" ]]; then
  [[ -f "$target/.github/workflows/ci.yml" ]] || add_missing "ci-workflow" ".github/workflows/ci.yml" "profile.ci.enabled=true but no CI workflow present"
fi

# GitHub templates: detect missing PR template when profile.extras.github_templates=true
if [[ "$(jq -r '.extras.github_templates // false' <<<"$profile_json")" == "true" ]]; then
  [[ -f "$target/.github/PULL_REQUEST_TEMPLATE.md" ]] || add_missing "pr-template" ".github/PULL_REQUEST_TEMPLATE.md" "profile.extras.github_templates=true"
fi

# --- MISCONFIGURED: files present but content short of expectations ---------

if [[ -f "$target/.gitignore" ]]; then
  # Infer expected entries from stack heuristically:
  # - JS/TS projects expect node_modules/, .next/, dist/, coverage/, .env*.
  # - Python expects .venv/, __pycache__/, .pytest_cache/.
  expected_entries=()
  if [[ -f "$target/package.json" ]]; then
    expected_entries+=("node_modules/" ".next/" "dist/" "coverage/" ".env")
  fi
  if [[ -f "$target/pyproject.toml" || -f "$target/requirements.txt" ]]; then
    expected_entries+=(".venv/" "__pycache__/" ".pytest_cache/")
  fi

  if [[ ${#expected_entries[@]} -gt 0 ]]; then
    # Normalize gitignore contents so `coverage` and `coverage/` count as
    # matching. Strip trailing slashes and blank/comment lines.
    norm_file=$(mktemp -t nyann-gi-norm.XXXXXX)
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
      stripped="${trimmed%/}"
      printf '%s\n' "$stripped" >> "$norm_file"
    done < "$target/.gitignore"

    missing_entries=()
    for e in "${expected_entries[@]}"; do
      stripped="${e%/}"
      if ! grep -Fxq "$stripped" "$norm_file" 2>/dev/null; then
        missing_entries+=("$e")
      fi
    done
    rm -f "$norm_file"

    if [[ ${#missing_entries[@]} -gt 0 ]]; then
      csv=$(IFS=','; echo "${missing_entries[*]}")
      add_misconfigured ".gitignore" "missing stack-typical entries" "$csv"
    fi
  fi
fi

# Base/long-lived branches from profile.branching. Branch names can legitimately
# contain `/` and `-`; `while read` preserves them exactly (vs. word-splitting).
if [[ -d "$target/.git" ]]; then
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    if ! git -C "$target" rev-parse --verify "$b" >/dev/null 2>&1; then
      add_misconfigured "branch:$b" "base branch declared by profile does not exist" ""
    fi
  done < <(jq -r '.branching.base_branches[]?' <<<"$profile_json")
  if [[ "$(jq -r '.branching.strategy' <<<"$profile_json")" == "gitflow" ]]; then
    if ! git -C "$target" rev-parse --verify develop >/dev/null 2>&1; then
      add_misconfigured "branch:develop" "GitFlow strategy requires a develop branch" ""
    fi
  fi
fi

# --- NON-COMPLIANT HISTORY: scan last N commit subjects ---------------------

cc_regex='^(feat|fix|chore|docs|refactor|test|perf|ci|build|style|revert)(\([^)]+\))?!?: .+'
checked=0
if [[ -d "$target/.git" ]] && git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
  # Skip merge/revert autogenerated subjects.
  while IFS= read -r sha && IFS= read -r subject; do
    checked=$((checked + 1))
    case "$subject" in
      "Merge "*|"Revert "*|"fixup! "*|"squash! "*|"amend! "*) continue ;;
    esac
    if ! [[ "$subject" =~ $cc_regex ]]; then
      offenders_json=$(jq --arg sha "$sha" --arg subject "$subject" '
        . + [{ sha: $sha, subject: $subject }]
      ' <<<"$offenders_json")
    fi
  done < <(git -C "$target" log -n "$commit_scan" --pretty=tformat:$'%h\n%s' 2>/dev/null)
fi

# --- emit --------------------------------------------------------------------

n_missing=$(jq 'length' <<<"$missing_json")
n_mis=$(jq 'length' <<<"$misconfigured_json")
n_off=$(jq 'length' <<<"$offenders_json")

# --- DOCUMENTATION tier: CLAUDE.md size + link check + orphans --------------

# Previously each subsystem call was `cmd 2>/dev/null || echo
# '<clean-looking fallback>'`, which hid real failures (corrupted
# CLAUDE.md, permissions errors, jq failures) as `status:"absent"` or
# empty arrays. That masked broken links, orphans, and staleness from
# the user. Now stderr is captured, fallbacks are only used when the
# subsystem would naturally produce them, and any real failure is
# surfaced in `documentation.subsystem_errors[]` so the consumer can
# warn rather than mistake it for clean state.
#
# Error records are written to a side file (not a bash variable)
# because `out=$(run_subsystem ...)` is a subshell — variable updates
# inside wouldn't survive. The file is slurped + parsed at the end.
norm_file=""
subsys_err=$(mktemp -t nyann-driftsub.XXXXXX)
subsys_errors_file=$(mktemp -t nyann-driftsub-errs.XXXXXX)
trap 'rm -f ${norm_file:+"$norm_file"} "$subsys_err" "$subsys_errors_file"' EXIT

run_subsystem() {
  # Usage: run_subsystem <name> <fallback-json> <cmd> [args...]
  # Emits the subsystem's stdout on success. On non-zero, emits the
  # fallback JSON and appends an error record (as a single JSON line)
  # to $subsys_errors_file.
  local name="$1" fallback="$2"
  shift 2
  : > "$subsys_err"
  local out
  if out=$("$@" 2>"$subsys_err"); then
    printf '%s' "$out"
    return 0
  fi
  local err_text
  err_text=$(head -c 500 "$subsys_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  [[ -z "$err_text" ]] && err_text="subsystem exited non-zero with no stderr output"
  jq -nc --arg n "$name" --arg e "$err_text" '{subsystem:$n, error:$e}' \
    >> "$subsys_errors_file"
  printf '%s' "$fallback"
}

# These run_subsystem calls are intentionally SEQUENTIAL.
# run_subsystem appends JSON records to $subsys_errors_file via `>>`,
# which is atomic-per-line on Linux (pipes < PIPE_BUF) but NOT reliably
# atomic on macOS HFS+/APFS when multiple subshells append at once.
# Parallelising these (e.g. `& wait`) requires coordinating the append
# (flock, per-subsystem file, or in-memory accumulation) before it's
# safe. Keep serial until someone redesigns the coordination.
claude_md_json=$(run_subsystem check-claude-md-size \
  '{"status":"absent","bytes":0,"budget_bytes":3072}' \
  "${_script_dir}/check-claude-md-size.sh" --target "$target" --profile "$profile_path")
links_json=$(run_subsystem check-links \
  '{"checked":0,"broken":[],"needs_mcp_verify":[],"skipped":[]}' \
  "${_script_dir}/check-links.sh" --target "$target")
orphans_json=$(run_subsystem find-orphans \
  '{"scanned":0,"orphans":[]}' \
  "${_script_dir}/find-orphans.sh" --target "$target")
staleness_json=$(run_subsystem check-staleness \
  '{"enabled":false,"threshold_days":null,"scanned":0,"stale":[]}' \
  "${_script_dir}/check-staleness.sh" --target "$target" --profile "$profile_path")

n_broken=$(jq '.broken | length' <<<"$links_json")
n_orphans=$(jq '.orphans | length' <<<"$orphans_json")
n_stale=$(jq '.stale | length' <<<"$staleness_json")
claude_md_status=$(jq -r '.status' <<<"$claude_md_json")

# Collect subsystem errors from the side file into a JSON array.
subsystem_errors_json='[]'
if [[ -s "$subsys_errors_file" ]]; then
  subsystem_errors_json=$(jq -s '.' "$subsys_errors_file")
fi
n_subsys_errs=$(jq 'length' <<<"$subsystem_errors_json")

jq -n \
  --arg target "$target" \
  --arg profile "$profile_name" \
  --argjson missing "$missing_json" \
  --argjson misconfigured "$misconfigured_json" \
  --argjson checked "$checked" \
  --argjson offenders "$offenders_json" \
  --argjson claude_md "$claude_md_json" \
  --argjson links "$links_json" \
  --argjson orphans "$orphans_json" \
  --argjson staleness "$staleness_json" \
  --argjson subsys_errors "$subsystem_errors_json" \
  --argjson n_missing "$n_missing" \
  --argjson n_mis "$n_mis" \
  --argjson n_off "$n_off" \
  --argjson n_broken "$n_broken" \
  --argjson n_orphans "$n_orphans" \
  --argjson n_stale "$n_stale" \
  --argjson n_subsys_errs "$n_subsys_errs" \
  --arg claude_md_status "$claude_md_status" \
  '{
    target: $target,
    profile: $profile,
    missing: $missing,
    misconfigured: $misconfigured,
    non_compliant_history: { checked: $checked, offenders: $offenders },
    documentation: {
      subsystem_errors: $subsys_errors,
      claude_md: $claude_md,
      links: $links,
      orphans: $orphans,
      staleness: $staleness
    },
    summary: {
      missing: $n_missing,
      misconfigured: $n_mis,
      non_compliant_commits: $n_off,
      broken_links: $n_broken,
      orphans: $n_orphans,
      stale_docs: $n_stale,
      subsystem_errors: $n_subsys_errs,
      claude_md_status: $claude_md_status
    }
  }'
