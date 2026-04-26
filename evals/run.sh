#!/usr/bin/env bash
# evals/run.sh — run nyann's skill-level evals.
#
# Two tiers:
#
#   output_quality_scenarios[] — deterministic: run bin/bootstrap.sh
#     end-to-end against a fixture, then check file assertions. Does NOT
#     require a live Claude Code install.
#
#   trigger_cases[] — requires a live LLM to decide "would Claude fire
#     this skill?". Out of reach of a pure shell harness. This script
#     prints them as a spec; a real eval harness (Anthropic's internal
#     tooling or a future nightly CI) is expected to consume the JSON
#     directly. Absence of a live harness is a skipped-with-reason, not
#     a failure.
#
# Usage:
#   evals/run.sh                     # run all scenarios in bootstrap-project.evals.json
#   evals/run.sh --file <eval.json>  # point at a specific eval spec
#   evals/run.sh --list              # list scenarios without running
#
# Exit codes:
#   0 — all output-quality scenarios passed
#   1 — at least one scenario failed
#   2 — eval file malformed

set -o errexit
set -o nounset
set -o pipefail

eval_file="evals/bootstrap-project.evals.json"
list_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    eval_file="${2:-}"; shift 2 ;;
    --file=*)  eval_file="${1#--file=}"; shift ;;
    --list)    list_only=true; shift ;;
    -h|--help) sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

[[ -f "$eval_file" ]] || { echo "eval file not found: $eval_file" >&2; exit 2; }

jq -e 'type == "object" and has("skill") and has("output_quality_scenarios")' "$eval_file" >/dev/null \
  || { echo "eval file missing required keys (skill, output_quality_scenarios)" >&2; exit 2; }

if $list_only; then
  echo "trigger cases:"
  jq -r '.trigger_cases[] | "  " + (if .should_trigger then "YES" else "no " end) + "\t" + .prompt' "$eval_file"
  echo
  echo "output-quality scenarios:"
  jq -r '.output_quality_scenarios[] | "  " + .name + "  (fixture=" + .fixture + ", profile=" + .profile + ")"' "$eval_file"
  exit 0
fi

# --- output-quality execution ----------------------------------------------

pass=0
fail=0
failed_names=()

run_scenario() {
  local name fixture profile project_name mode needs_seed expected_exit
  name=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].name' "$eval_file")
  fixture=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].fixture' "$eval_file")
  profile=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].profile' "$eval_file")
  project_name=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].project_name // "eval"' "$eval_file")
  mode=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].mode // "bootstrap"' "$eval_file")
  needs_seed=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].needs_seed // false' "$eval_file")
  expected_exit=$(jq -r --arg i "$1" '.output_quality_scenarios[$i|tonumber].expected_exit // 0' "$eval_file")

  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" RETURN

  # Seed the fixture into a fresh temp dir (never mutate the real fixture).
  if [[ -d "$repo_root/$fixture" ]]; then
    cp -r "$repo_root/$fixture/." "$tmp/"
  fi

  # Fixtures that ship a seed.sh (e.g. legacy-with-drift) build their git
  # history on demand. Run it if requested.
  if [[ "$needs_seed" == "true" && -x "$tmp/seed.sh" ]]; then
    ( cd "$tmp" && ./seed.sh >/dev/null 2>&1 )
  fi

  local doctor_text="" doctor_json="" doctor_exit=0

  if [[ "$mode" == "learn_profile_fixture" ]]; then
    # Copy the fixture into tmp, run its seed.sh (if requested), then invoke
    # learn-profile with a sandboxed user-root. Walk expected_fields and
    # compare each to jq's read of the emitted profile.
    ( cd "$tmp" && [[ "$needs_seed" == "true" && -x seed.sh ]] && ./seed.sh >/dev/null 2>&1 || true )

    local ur="$tmp/user-root"
    mkdir -p "$ur/profiles"
    if ! bash "$repo_root/bin/learn-profile.sh" --target "$tmp" --name evalp --user-root "$ur" >/dev/null 2>&1; then
      echo "  ✗ [$name] learn-profile.sh exited non-zero" >&2
      fail=$((fail + 1))
      failed_names+=("$name")
      return 0
    fi
    local outp="$ur/profiles/evalp.json"
    local mismatches=0

    # Iterate expected_fields {key: expected}, comparing with `jq -r`.
    while IFS=$'\t' read -r key expected; do
      [[ -z "$key" ]] && continue
      local actual
      actual=$(jq -r --arg k "$key" 'getpath($k | split("."))' "$outp")
      if [[ "$actual" != "$expected" ]]; then
        echo "  ✗ [$name] expected_fields.$key = '$expected', got '$actual'" >&2
        mismatches=$((mismatches + 1))
      fi
    done < <(jq -r --arg s "$1" '
      .output_quality_scenarios[$s|tonumber].expected_fields
      | to_entries[]
      | "\(.key)\t\(.value)"
    ' "$eval_file")

    if (( mismatches == 0 )); then
      echo "  ✓ $name (expected_fields all match)"
      pass=$((pass + 1))
    else
      echo "  ✗ $name ($mismatches mismatch(es))"
      fail=$((fail + 1))
      failed_names+=("$name")
    fi
    return 0
  fi

  if [[ "$mode" == "commit_msg_hook" ]]; then
    # Install core hooks into tmp, then feed each message through the
    # commit-msg hook and count failures.
    ( cd "$tmp" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "chore: seed" )
    "$repo_root/bin/install-hooks.sh" --target "$tmp" --core > /dev/null 2>&1

    local msg_count msgs_failed=0 i
    msg_count=$(jq --arg s "$1" '.output_quality_scenarios[$s|tonumber].messages | length' "$eval_file")
    for ((i = 0; i < msg_count; i++)); do
      msg=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].messages[$i|tonumber]' "$eval_file")
      echo "$msg" > "$tmp/.COMMIT_EDITMSG"
      if ! bash "$tmp/.git/hooks/commit-msg" "$tmp/.COMMIT_EDITMSG" >/dev/null 2>&1; then
        echo "  ✗ [$name] message rejected: $msg" >&2
        msgs_failed=$((msgs_failed + 1))
      fi
    done
    if (( msgs_failed == 0 )); then
      echo "  ✓ $name ($msg_count message(s) pass commit-msg hook)"
      pass=$((pass + 1))
    else
      echo "  ✗ $name ($msgs_failed/$msg_count message(s) failed)"
      fail=$((fail + 1))
      failed_names+=("$name")
    fi
    return 0
  fi

  if [[ "$mode" == "branch_name_fixtures" ]]; then
    # For each case, seed a fresh temp repo (+ optional synthetic profile),
    # run new-branch.sh, and verify the created branch matches expectations.
    local case_count case_failed=0 j
    case_count=$(jq --arg s "$1" '.output_quality_scenarios[$s|tonumber].cases | length' "$eval_file")

    local user_root="$tmp/user-root"
    mkdir -p "$user_root/profiles"
    # Self-contained synthetic GitFlow profile so the acceptance matrix
    # has a way to exercise GitFlow without mutating the real $HOME.
    cat > "$user_root/profiles/synthetic-gitflow.json" <<'JSON'
{
  "$schema": "https://nyann.dev/schemas/profile/v1.json",
  "name": "synthetic-gitflow",
  "schemaVersion": 1,
  "stack": { "primary_language": "typescript" },
  "branching": {
    "strategy": "gitflow",
    "base_branches": ["main"],
    "branch_name_patterns": {
      "feature": "feat/{slug}",
      "bugfix":  "fix/{slug}",
      "release": "release/{version}",
      "hotfix":  "hotfix/{slug}"
    }
  },
  "hooks": { "pre_commit": [], "commit_msg": [], "pre_push": [] },
  "extras": {},
  "conventions": { "commit_format": "conventional-commits" },
  "documentation": { "scaffold_types": [], "storage_strategy": "local", "claude_md_mode": "router" }
}
JSON

    for ((j = 0; j < case_count; j++)); do
      profile_ref=$(jq -r --arg s "$1" --arg j "$j" '.output_quality_scenarios[$s|tonumber].cases[$j|tonumber].strategy_profile' "$eval_file")
      cpurpose=$(jq -r --arg s "$1" --arg j "$j" '.output_quality_scenarios[$s|tonumber].cases[$j|tonumber].purpose' "$eval_file")
      cslug=$(jq -r --arg s "$1" --arg j "$j" '.output_quality_scenarios[$s|tonumber].cases[$j|tonumber].slug // ""' "$eval_file")
      cversion=$(jq -r --arg s "$1" --arg j "$j" '.output_quality_scenarios[$s|tonumber].cases[$j|tonumber].version // ""' "$eval_file")
      expected_branch=$(jq -r --arg s "$1" --arg j "$j" '.output_quality_scenarios[$s|tonumber].cases[$j|tonumber].expected_branch' "$eval_file")
      expected_base=$(jq -r --arg s "$1" --arg j "$j" '.output_quality_scenarios[$s|tonumber].cases[$j|tonumber].expected_base' "$eval_file")

      case_dir=$(mktemp -d -t nyann-branch-case.XXXXXX)
      ( cd "$case_dir" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed" )
      if [[ "$profile_ref" == "synthetic-gitflow" ]]; then
        git -C "$case_dir" branch develop
      fi

      args=(--target "$case_dir" --profile "$profile_ref" --purpose "$cpurpose" --checkout --user-root "$user_root")
      [[ -n "$cslug"    ]] && args+=(--slug "$cslug")
      [[ -n "$cversion" ]] && args+=(--version "$cversion")

      if ! bash "$repo_root/bin/new-branch.sh" "${args[@]}" > /dev/null 2>&1; then
        echo "  ✗ [$name] case $j ($profile_ref/$cpurpose) → new-branch.sh exited non-zero" >&2
        case_failed=$((case_failed + 1))
        rm -rf "$case_dir"
        continue
      fi

      actual_branch=$(git -C "$case_dir" branch --show-current)
      actual_base_sha=$(git -C "$case_dir" rev-parse "$expected_base" 2>/dev/null || echo "")
      actual_branch_base=$(git -C "$case_dir" merge-base "$actual_branch" "$expected_base" 2>/dev/null || echo "")

      if [[ "$actual_branch" != "$expected_branch" ]]; then
        echo "  ✗ [$name] case $j: branch '$actual_branch' != expected '$expected_branch'" >&2
        case_failed=$((case_failed + 1))
      elif [[ -z "$actual_base_sha" || "$actual_branch_base" != "$actual_base_sha" ]]; then
        echo "  ✗ [$name] case $j: $actual_branch not descended from '$expected_base'" >&2
        case_failed=$((case_failed + 1))
      fi

      rm -rf "$case_dir"
    done

    if (( case_failed == 0 )); then
      echo "  ✓ $name ($case_count case(s) passed)"
      pass=$((pass + 1))
    else
      echo "  ✗ $name ($case_failed/$case_count case(s) failed)"
      fail=$((fail + 1))
      failed_names+=("$name")
    fi
    return 0
  fi

  if [[ "$mode" == "doctor" ]]; then
    set +e
    doctor_text=$("$repo_root/bin/doctor.sh" --target "$tmp" --profile "$profile" 2>&1)
    doctor_exit=$?
    doctor_json=$("$repo_root/bin/doctor.sh" --target "$tmp" --profile "$profile" --json 2>/dev/null)
    set -e
    printf '%s' "$doctor_json" > "$tmp/.summary.json"
    printf '%s' "$doctor_text" > "$tmp/.run.log"
  else
    # bootstrap mode
    "$repo_root/bin/detect-stack.sh" --path "$tmp" > "$tmp/.stack.json"
    "$repo_root/bin/route-docs.sh" --profile "$repo_root/profiles/${profile}.json" > "$tmp/.docplan.json"
    # Plan declares every file bootstrap is expected to materialise
    # (preview-before-mutate gates .editorconfig, CLAUDE.md, docs/*,
    # memory/*). Matches what the skill layer would compose before
    # handing off to bootstrap.sh.
    cat > "$tmp/.plan.json" <<'JSON'
{"writes":[
  {"path":".editorconfig","action":"create","bytes":0},
  {"path":"CLAUDE.md","action":"create","bytes":0},
  {"path":"docs/README.md","action":"create","bytes":0},
  {"path":"docs/architecture.md","action":"create","bytes":0},
  {"path":"docs/prd.md","action":"create","bytes":0},
  {"path":"docs/decisions/README.md","action":"create","bytes":0},
  {"path":"docs/research/README.md","action":"create","bytes":0},
  {"path":"memory/README.md","action":"create","bytes":0}
],"commands":[],"remote":[]}
JSON

    "$repo_root/bin/bootstrap.sh" \
      --target "$tmp" \
      --plan "$tmp/.plan.json" \
      --profile "$repo_root/profiles/${profile}.json" \
      --doc-plan "$tmp/.docplan.json" \
      --stack "$tmp/.stack.json" \
      --project-name "$project_name" \
      > "$tmp/.summary.json" 2> "$tmp/.run.log"
  fi

  # Walk assertions.
  local failed_this=0 assert_count i
  assert_count=$(jq --arg i "$1" '.output_quality_scenarios[$i|tonumber].assertions | length' "$eval_file")
  for ((i = 0; i < assert_count; i++)); do
    local kind path expected_sub bytes
    kind=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].kind' "$eval_file")
    path=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].path' "$eval_file")
    case "$kind" in
      file_exists)
        if [[ ! -e "$tmp/$path" ]]; then
          echo "  ✗ [$name] file_exists: $path (missing)" >&2
          failed_this=1
        fi
        ;;
      file_contains)
        expected_sub=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].substring' "$eval_file")
        if [[ ! -e "$tmp/$path" ]] || ! grep -Fq -- "$expected_sub" "$tmp/$path"; then
          echo "  ✗ [$name] file_contains: $path lacks '$expected_sub'" >&2
          failed_this=1
        fi
        ;;
      file_size_max)
        bytes=$(jq --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].bytes' "$eval_file")
        if [[ ! -f "$tmp/$path" ]]; then
          echo "  ✗ [$name] file_size_max: $path missing" >&2
          failed_this=1
        else
          local actual
          actual=$(wc -c < "$tmp/$path" | tr -d ' ')
          if (( actual > bytes )); then
            echo "  ✗ [$name] file_size_max: $path is $actual B > $bytes B" >&2
            failed_this=1
          fi
        fi
        ;;
      drift_summary_nonzero)
        field=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].field' "$eval_file")
        val=$(jq --arg f "$field" '.summary[$f]' "$tmp/.summary.json")
        if [[ "$val" == "null" || "$val" == "0" ]]; then
          echo "  ✗ [$name] drift_summary_nonzero: summary.$field is $val" >&2
          failed_this=1
        fi
        ;;
      drift_section_present)
        section=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].section' "$eval_file")
        if ! grep -Fq "$section" "$tmp/.run.log"; then
          echo "  ✗ [$name] drift_section_present: '$section' not in doctor output" >&2
          failed_this=1
        fi
        ;;
      drift_missing_entry_contains)
        sub=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].substring' "$eval_file")
        if ! jq -e --arg sub "$sub" '.missing[] | select(.path | contains($sub))' "$tmp/.summary.json" >/dev/null; then
          echo "  ✗ [$name] drift_missing_entry_contains: no .missing[].path contains '$sub'" >&2
          failed_this=1
        fi
        ;;
      drift_misconfigured_path_contains)
        sub=$(jq -r --arg s "$1" --arg i "$i" '.output_quality_scenarios[$s|tonumber].assertions[$i|tonumber].substring' "$eval_file")
        if ! jq -e --arg sub "$sub" '.misconfigured[] | select(.path | contains($sub))' "$tmp/.summary.json" >/dev/null; then
          echo "  ✗ [$name] drift_misconfigured_path_contains: no .misconfigured[].path contains '$sub'" >&2
          failed_this=1
        fi
        ;;
      *) echo "  ✗ [$name] unknown assertion kind: $kind" >&2; failed_this=1 ;;
    esac
  done

  # Check expected exit code for doctor-mode scenarios.
  if [[ "$mode" == "doctor" ]] && [[ "$doctor_exit" != "$expected_exit" ]]; then
    echo "  ✗ [$name] expected_exit: got $doctor_exit, want $expected_exit" >&2
    failed_this=1
  fi

  if (( failed_this == 0 )); then
    echo "  ✓ $name ($assert_count assertion(s) passed)"
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
}

scenario_count=$(jq '.output_quality_scenarios | length' "$eval_file")
echo "running $scenario_count output-quality scenario(s) from $eval_file"
for ((i = 0; i < scenario_count; i++)); do
  run_scenario "$i"
done

echo
echo "results: $pass passed, $fail failed"
if (( fail > 0 )); then
  printf 'failed: %s\n' "${failed_names[@]}"
  exit 1
fi

# --- trigger-case notice ---------------------------------------------------
echo
echo "trigger_cases are declarative specs for a live-model harness. See"
echo "evals/README.md for the eval-tier policy; this script does not execute them."
