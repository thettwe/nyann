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
scope="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --profile)       profile_path="${2:-}"; shift 2 ;;
    --profile=*)     profile_path="${1#--profile=}"; shift ;;
    --commit-scan)   commit_scan="${2:-20}"; shift 2 ;;
    --commit-scan=*) commit_scan="${1#--commit-scan=}"; shift ;;
    --scope)         scope="${2:-all}"; shift 2 ;;
    --scope=*)       scope="${1#--scope=}"; shift ;;
    -h|--help)       sed -n '3,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
target="$(cd "$target" && pwd)"

# Validate --scope. Reject unknown categories up front so the operator
# sees `unknown scope: dox` instead of a quietly-empty report. Categories
# are namespaced to subsystems (compute-drift / retrofit / bootstrap all
# read this same set via nyann::scope_includes).
if ! _bad_scope=$(nyann::valid_scope_csv "$scope"); then
  nyann::die "unknown scope: $_bad_scope (want any of: docs hooks branching gitignore editorconfig github history all)"
fi
scope_canonical=$(nyann::canonical_scope "$scope")

# Install the cleanup trap up-front. _drift_tmpdir (parallel doc
# subsystems) is created mid-script; a SIGINT/SIGTERM between creation
# and the trap install would leak the tmpdir. Initialising to "" and
# guarding with ${var:+} keeps the trap safe at any point in the run.
_drift_tmpdir=""
trap 'rm -rf ${_drift_tmpdir:+"$_drift_tmpdir"}' EXIT

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
misplaced_json='[]'

add_missing() {
  # $1=kind $2=path $3=detail
  missing_json=$(jq --arg kind "$1" --arg path "$2" --arg detail "${3:-}" '
    . + [{ kind: $kind, path: $path } + ( if $detail != "" then { detail: $detail } else {} end )]
  ' <<<"$missing_json")
}

add_misplaced() {
  # $1=source (actual path) $2=target (canonical path) $3=category $4=confidence
  misplaced_json=$(jq --arg s "$1" --arg t "$2" --arg c "$3" --argjson conf "$4" '
    . + [{ source: $s, target: $t, category: $c, confidence: $conf }]
  ' <<<"$misplaced_json")
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

if nyann::scope_includes gitignore "$scope"; then
  if [[ "$(jq -r '.extras.gitignore // false' <<<"$profile_json")" == "true" ]]; then
    [[ -f "$target/.gitignore" ]] || add_missing "gitignore" ".gitignore" "profile.extras.gitignore=true but no .gitignore present"
  fi
fi
if nyann::scope_includes docs "$scope"; then
  if [[ "$(jq -r '.extras.claude_md // false' <<<"$profile_json")" == "true" ]]; then
    [[ -f "$target/CLAUDE.md" ]] || add_missing "claude-md" "CLAUDE.md" "profile.extras.claude_md=true"
  fi
fi
if nyann::scope_includes editorconfig "$scope"; then
  if [[ "$(jq -r '.extras.editorconfig // false' <<<"$profile_json")" == "true" ]]; then
    [[ -f "$target/.editorconfig" ]] || add_missing "editorconfig" ".editorconfig" ""
  fi
fi

# Hook files: presence of eslint/prettier/commitlint in profile.hooks
# implies Husky setup; presence of ruff/commitizen implies pre-commit.com.
# Check for the managed hook files we write.
hook_list=$(jq -r '[(.hooks.pre_commit // [])[], (.hooks.commit_msg // [])[]] | join(" ")' <<<"$profile_json")
if nyann::scope_includes hooks "$scope"; then
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
fi

# Doc scaffolding: check documentation.scaffold_types AND, when the
# profile opts into archetype-aware scaffolding, the per-archetype
# doc set. Use `while read` rather than `for t in $(jq …)` so values
# containing whitespace (or IFS-sensitive characters from
# team-sourced profiles) don't word-split.
#
# When profile.documentation.use_archetype_scaffolds:true AND
# profile.archetype is set (and not "unknown"), the expected doc set
# is the UNION of scaffold_types[] and the archetype map's types.
# This lets retrofit surface archetype-specific doc gaps (api-reference,
# runbook, deployment, glossary) that the flat scaffold_types list
# alone wouldn't catch.
prof_use_archetype=$(jq -r '.documentation.use_archetype_scaffolds // false' <<<"$profile_json")
prof_archetype=$(jq -r '.archetype // ""' <<<"$profile_json")

if [[ "$prof_use_archetype" == "true" && -n "$prof_archetype" && "$prof_archetype" != "unknown" ]]; then
  expected_types_json=$(nyann::archetype_scaffold_types "$prof_archetype" \
    | jq -nR --argjson p "$(jq '.documentation.scaffold_types // []' <<<"$profile_json")" \
        '[inputs] + $p | unique')
else
  expected_types_json=$(jq '.documentation.scaffold_types // []' <<<"$profile_json")
fi

if nyann::scope_includes docs "$scope"; then
  # v1.9.0: run conformance detection once to identify docs at non-canonical paths.
  # This lets us distinguish "missing" (no content anywhere) from "misplaced"
  # (content exists but at wrong path).
  _conformance_json='[]'
  if [[ -x "${_script_dir}/detect-doc-conformance.sh" ]]; then
    _conformance_err=$(mktemp -t nyann-conformance-err.XXXXXX)
    if _conformance_out=$("${_script_dir}/detect-doc-conformance.sh" \
        --target "$target" --archetype "${prof_archetype:-unknown}" 2>"$_conformance_err"); then
      _conformance_json="$_conformance_out"
    else
      _conformance_rc=$?
      _conformance_msg=$(tr '\n' ' ' < "$_conformance_err" | sed 's/  */ /g; s/^ //; s/ $//')
      nyann::warn "doc conformance detection failed (rc=$_conformance_rc); continuing with empty result: ${_conformance_msg:-no stderr output}"
      _conformance_json='[]'
    fi
    rm -f "$_conformance_err"
  fi

  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    _is_present=false
    case "$t" in
      architecture)  [[ -f "$target/docs/architecture.md" ]]  && _is_present=true ;;
      prd)           [[ -f "$target/docs/prd.md" ]]           && _is_present=true ;;
      adrs)          [[ -f "$target/docs/decisions/ADR-000-record-architecture-decisions.md" ]] && _is_present=true ;;
      research)      [[ -d "$target/docs/research" ]]         && _is_present=true ;;
      api_reference) [[ -f "$target/docs/api-reference.md" ]] && _is_present=true ;;
      runbook)       [[ -f "$target/docs/runbook.md" ]]       && _is_present=true ;;
      deployment)    [[ -f "$target/docs/deployment.md" ]]    && _is_present=true ;;
      glossary)      [[ -f "$target/docs/glossary.md" ]]      && _is_present=true ;;
    esac
    if $_is_present; then
      continue
    fi
    # Check if conformance detection found a non-canonical equivalent
    _conf_match=$(jq -r --arg cat "$t" '.[] | select(.category == $cat) | .source' <<<"$_conformance_json" | head -1)
    if [[ -n "$_conf_match" ]]; then
      _conf_confidence=$(jq -r --arg cat "$t" '.[] | select(.category == $cat) | .confidence' <<<"$_conformance_json" | head -1)
      _conf_target=$(jq -r --arg cat "$t" '.[] | select(.category == $cat) | .target' <<<"$_conformance_json" | head -1)
      add_misplaced "$_conf_match" "$_conf_target" "$t" "${_conf_confidence:-0.7}"
    else
      case "$t" in
        architecture)  add_missing "doc" "docs/architecture.md"  "profile scaffolds architecture" ;;
        prd)           add_missing "doc" "docs/prd.md"           "profile scaffolds prd" ;;
        adrs)          add_missing "doc" "docs/decisions/ADR-000-record-architecture-decisions.md" "profile scaffolds ADRs" ;;
        research)      add_missing "doc" "docs/research"         "profile scaffolds research" ;;
        api_reference) add_missing "doc" "docs/api-reference.md" "archetype scaffolds api-reference" ;;
        runbook)       add_missing "doc" "docs/runbook.md"       "archetype scaffolds runbook" ;;
        deployment)    add_missing "doc" "docs/deployment.md"    "archetype scaffolds deployment" ;;
        glossary)      add_missing "doc" "docs/glossary.md"      "archetype scaffolds glossary" ;;
      esac
    fi
  done < <(jq -r '.[]?' <<<"$expected_types_json")
fi

if nyann::scope_includes github "$scope"; then
  # CI workflow: detect missing .github/workflows/ci.yml when profile.ci.enabled=true
  if [[ "$(jq -r '.ci.enabled // false' <<<"$profile_json")" == "true" ]]; then
    [[ -f "$target/.github/workflows/ci.yml" ]] || add_missing "ci-workflow" ".github/workflows/ci.yml" "profile.ci.enabled=true but no CI workflow present"
  fi

  # GitHub templates: detect missing PR template when profile.extras.github_templates=true
  if [[ "$(jq -r '.extras.github_templates // false' <<<"$profile_json")" == "true" ]]; then
    [[ -f "$target/.github/PULL_REQUEST_TEMPLATE.md" ]] || add_missing "pr-template" ".github/PULL_REQUEST_TEMPLATE.md" "profile.extras.github_templates=true"
  fi
fi

# --- MISCONFIGURED: files present but content short of expectations ---------

if nyann::scope_includes gitignore "$scope" && [[ -f "$target/.gitignore" ]]; then
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
    # Normalize gitignore + diff against expected entries in one pass:
    # awk reads .gitignore (lstrip, drop blanks/comments, strip trailing
    # `/`) into a hash; expected entries are also stripped and compared.
    # Replaces the previous read-loop + per-entry `grep -Fxq` (~8 grep
    # forks for 8 expected entries) with a single awk fork.
    missing_entries=()
    while IFS= read -r e; do
      [[ -z "$e" ]] && continue
      missing_entries+=("$e")
    done < <(awk -v want_csv="$(IFS=,; printf '%s' "${expected_entries[*]}")" '
      # NB: variable names avoid `exp` because BSD awk on macOS treats it
      # as a reserved (math) builtin and refuses array indexing into it.
      BEGIN {
        n = split(want_csv, raw, ",")
        for (i = 1; i <= n; i++) {
          w = raw[i]
          sub(/\/$/, "", w)
          if (w != "") { want[i] = w; orig[i] = raw[i] }
        }
      }
      {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line == "" || substr(line, 1, 1) == "#") next
        sub(/\/$/, "", line)
        seen[line] = 1
      }
      END {
        for (i = 1; i <= n; i++) {
          if (want[i] == "") continue
          if (!(want[i] in seen)) print orig[i]
        }
      }
    ' "$target/.gitignore")

    if [[ ${#missing_entries[@]} -gt 0 ]]; then
      csv=$(IFS=','; echo "${missing_entries[*]}")
      add_misconfigured ".gitignore" "missing stack-typical entries" "$csv"
    fi
  fi
fi

# Base/long-lived branches from profile.branching. Branch names can legitimately
# contain `/` and `-`; `while read` preserves them exactly (vs. word-splitting).
if nyann::scope_includes branching "$scope" && [[ -d "$target/.git" ]]; then
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
if nyann::scope_includes history "$scope" \
   && [[ -d "$target/.git" ]] \
   && git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
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
n_misplaced=$(jq 'length' <<<"$misplaced_json")

# --- DOCUMENTATION tier: CLAUDE.md size + link check + orphans --------------

# Each doc subsystem writes to its own pair of output files (stdout +
# stderr), solving the macOS APFS append-atomicity concern that
# previously forced serial execution. All four subsystems now run in
# parallel via background jobs + wait. Cleanup trap is installed at
# top-of-script so partial state is cleaned up on SIGINT.
_drift_tmpdir=$(mktemp -d -t nyann-driftsubs.XXXXXX)

_subsys_names=(check-claude-md-size check-links find-orphans check-staleness)
# Failure fallbacks (subsystem ran, returned non-zero). Used when the
# subsystem is in scope but errored.
_subsys_fallbacks=(
  '{"status":"absent","bytes":0,"budget_bytes":3072}'
  '{"checked":0,"broken":[],"needs_mcp_verify":[],"skipped":[]}'
  '{"scanned":0,"orphans":[]}'
  '{"enabled":false,"threshold_days":null,"scanned":0,"stale":[]}'
)
# Out-of-scope fallbacks (subsystem deliberately not run). Distinct
# `status:"skipped"` lets retrofit/doctor avoid double-counting
# "we didn't check this" as drift, so a clean `--scope hooks` run
# can exit 0 on a repo that lacks CLAUDE.md.
_subsys_skipped_fallbacks=(
  '{"status":"skipped","bytes":0,"budget_bytes":3072}'
  '{"checked":0,"broken":[],"needs_mcp_verify":[],"skipped":[]}'
  '{"scanned":0,"orphans":[]}'
  '{"enabled":false,"threshold_days":null,"scanned":0,"stale":[]}'
)
# When `docs` is out of scope we still emit the same field shapes (the
# DriftReport schema doesn't allow them to be absent), but we use the
# fallback payloads directly instead of forking four subsystems we'd
# discard the output of. Saves ~50ms on a typical retrofit --scope=hooks.
if nyann::scope_includes docs "$scope"; then
  for i in 0 1 2 3; do
    (
      name="${_subsys_names[$i]}"
      out_f="$_drift_tmpdir/${name}.out"
      err_f="$_drift_tmpdir/${name}.err"
      case "$name" in
        check-claude-md-size) cmd=("${_script_dir}/check-claude-md-size.sh" --target "$target" --profile "$profile_path") ;;
        check-links)          cmd=("${_script_dir}/check-links.sh" --target "$target") ;;
        find-orphans)         cmd=("${_script_dir}/find-orphans.sh" --target "$target") ;;
        check-staleness)      cmd=("${_script_dir}/check-staleness.sh" --target "$target" --profile "$profile_path") ;;
      esac
      if "${cmd[@]}" >"$out_f" 2>"$err_f"; then
        :
      else
        printf '%s' "${_subsys_fallbacks[$i]}" > "$out_f"
        err_text=$(head -c 500 "$err_f" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        [[ -z "$err_text" ]] && err_text="subsystem exited non-zero with no stderr output"
        jq -nc --arg n "$name" --arg e "$err_text" '{subsystem:$n, error:$e}' \
          > "$_drift_tmpdir/${name}.errrec"
      fi
    ) &
  done
  wait
else
  for i in 0 1 2 3; do
    name="${_subsys_names[$i]}"
    # When docs is out of scope, mark the CLAUDE.md slot `skipped`
    # rather than `absent` so downstream exit-code logic can tell
    # "we didn't run this check" from "we ran it and the file is
    # missing". The latter is real drift; the former is not.
    printf '%s' "${_subsys_skipped_fallbacks[$i]}" > "$_drift_tmpdir/${name}.out"
  done
fi

claude_md_json=$(<"$_drift_tmpdir/check-claude-md-size.out")
links_json=$(<"$_drift_tmpdir/check-links.out")
orphans_json=$(<"$_drift_tmpdir/find-orphans.out")
staleness_json=$(<"$_drift_tmpdir/check-staleness.out")

n_broken=$(jq '.broken | length' <<<"$links_json")
n_orphans=$(jq '.orphans | length' <<<"$orphans_json")
n_stale=$(jq '.stale | length' <<<"$staleness_json")
claude_md_status=$(jq -r '.status' <<<"$claude_md_json")

# Collect subsystem errors from per-subsystem files.
subsystem_errors_json='[]'
shopt -s nullglob
_errrec_files=("$_drift_tmpdir"/*.errrec)
shopt -u nullglob
if [[ ${#_errrec_files[@]} -gt 0 ]]; then
  subsystem_errors_json=$(cat "${_errrec_files[@]}" | jq -s '.')
fi
n_subsys_errs=$(jq 'length' <<<"$subsystem_errors_json")

# Build scope_applied[] from the canonical CSV. "all" expands to the
# full list so consumers (doctor-ci, health-trend, retrofit) don't have
# to re-derive what "all" means; what they see is what was checked.
if [[ "$scope_canonical" == "all" ]]; then
  scope_applied_json='["docs","hooks","branching","gitignore","editorconfig","github","history"]'
else
  scope_applied_json=$(printf '%s' "$scope_canonical" | jq -Rc 'split(",")')
fi

jq -n \
  --arg target "$target" \
  --arg profile "$profile_name" \
  --argjson missing "$missing_json" \
  --argjson misconfigured "$misconfigured_json" \
  --argjson misplaced "$misplaced_json" \
  --argjson checked "$checked" \
  --argjson offenders "$offenders_json" \
  --argjson claude_md "$claude_md_json" \
  --argjson links "$links_json" \
  --argjson orphans "$orphans_json" \
  --argjson staleness "$staleness_json" \
  --argjson subsys_errors "$subsystem_errors_json" \
  --argjson scope_applied "$scope_applied_json" \
  --argjson n_missing "$n_missing" \
  --argjson n_mis "$n_mis" \
  --argjson n_off "$n_off" \
  --argjson n_misplaced "$n_misplaced" \
  --argjson n_broken "$n_broken" \
  --argjson n_orphans "$n_orphans" \
  --argjson n_stale "$n_stale" \
  --argjson n_subsys_errs "$n_subsys_errs" \
  --arg claude_md_status "$claude_md_status" \
  '{
    target: $target,
    profile: $profile,
    scope_applied: $scope_applied,
    missing: $missing,
    misconfigured: $misconfigured,
    misplaced: $misplaced,
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
      misplaced: $n_misplaced,
      non_compliant_commits: $n_off,
      broken_links: $n_broken,
      orphans: $n_orphans,
      stale_docs: $n_stale,
      subsystem_errors: $n_subsys_errs,
      claude_md_status: $claude_md_status
    }
  }'
