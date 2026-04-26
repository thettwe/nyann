#!/usr/bin/env bash
# learn-profile.sh — infer a nyann profile from a reference repo.
#
# Usage:
#   learn-profile.sh --target <repo> --name <profile-name>
#                    [--user-root <dir>] [--stdout]
#
# Output: writes the assembled profile JSON to
# <user-root>/profiles/<name>.json (default: ~/.claude/nyann/profiles/).
# Also emits the JSON on stdout when --stdout is passed. Uncertain fields
# carry an `inferred: true` marker so users can see what was guessed.
#
# Inference sources:
#   - bin/detect-stack.sh                 → stack block
#   - .husky/, .pre-commit-config.yaml,
#     commitlint.config.*, installed
#     git hooks                           → hooks block
#   - last 50 commit subjects             → conventions.commit_format
#   - branches + tags                     → branching.strategy
#   - .editorconfig + gitignore content    → extras

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_name=""
user_root="${HOME}/.claude/nyann"
to_stdout=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --name)         profile_name="${2:-}"; shift 2 ;;
    --name=*)       profile_name="${1#--name=}"; shift ;;
    --user-root)    user_root="${2:-}"; shift 2 ;;
    --user-root=*)  user_root="${1#--user-root=}"; shift ;;
    --stdout)       to_stdout=true; shift ;;
    -h|--help)      sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target must be an existing directory"
target="$(cd "$target" && pwd)"
[[ -n "$profile_name" ]] || nyann::die "--name is required"
if ! [[ "$profile_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  nyann::die "--name must match ^[a-z0-9][a-z0-9-]*$"
fi

# --- stack ------------------------------------------------------------------

stack_json=$("${_script_dir}/detect-stack.sh" --path "$target")
primary_language=$(jq -r '.primary_language' <<<"$stack_json")
framework=$(jq '.framework' <<<"$stack_json")
package_manager=$(jq '.package_manager' <<<"$stack_json")

# --- hooks block -------------------------------------------------------------
# Collect evidence per hook id; mark set inferred:true when we saw something
# that points at that hook.

pre_commit_list='[]'
commit_msg_list='[]'
pre_push_list='[]'

add_hook() {
  # $1 = which slot (pre_commit / commit_msg / pre_push) $2 = hook id
  local slot="$1" id="$2"
  case "$slot" in
    pre_commit)
      pre_commit_list=$(jq --arg id "$id" '. + [$id] | unique' <<<"$pre_commit_list") ;;
    commit_msg)
      commit_msg_list=$(jq --arg id "$id" '. + [$id] | unique' <<<"$commit_msg_list") ;;
    pre_push)
      pre_push_list=$(jq --arg id "$id" '. + [$id] | unique' <<<"$pre_push_list") ;;
  esac
}

# Husky artifacts imply the JS/TS lineage.
if [[ -f "$target/.husky/pre-commit" ]]; then
  grep -Fq "lint-staged"  "$target/.husky/pre-commit" 2>/dev/null && add_hook pre_commit lint-staged
  grep -Fq "eslint"       "$target/.husky/pre-commit" 2>/dev/null && add_hook pre_commit eslint
  grep -Fq "prettier"     "$target/.husky/pre-commit" 2>/dev/null && add_hook pre_commit prettier
  grep -Fq "gitleaks"     "$target/.husky/pre-commit" 2>/dev/null && add_hook pre_commit gitleaks
  grep -Eq "block-main|direct commits to main" "$target/.husky/pre-commit" 2>/dev/null && add_hook pre_commit block-main
fi
if [[ -f "$target/.husky/commit-msg" ]]; then
  grep -Fq "commitlint"  "$target/.husky/commit-msg" 2>/dev/null && add_hook commit_msg conventional-commits
fi
if [[ -f "$target/commitlint.config.js" || -f "$target/commitlint.config.cjs" || -f "$target/commitlint.config.mjs" ]]; then
  add_hook commit_msg conventional-commits
fi

# pre-commit.com hooks. Requires python3 + PyYAML; degrade with a
# log when either is missing so the user knows the learned profile
# won't capture framework-driven hooks.
precommit_dump=$(mktemp -t nyann-precommit.XXXXXX)
trap 'rm -f "$precommit_dump"' EXIT
if [[ -f "$target/.pre-commit-config.yaml" ]]; then
  if nyann::has_python_yaml; then
    python3 - "$target/.pre-commit-config.yaml" > "$precommit_dump" 2>/dev/null <<'PY' || true
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f) or {}
for r in cfg.get('repos', []):
    for h in r.get('hooks', []):
        hid = h.get('id', '') if isinstance(h, dict) else ''
        if hid:
            print(hid)
PY
  else
    nyann::warn "python3 + PyYAML not available; .pre-commit-config.yaml hooks will not be captured in the learned profile"
  fi
fi

if [[ -s "$precommit_dump" ]]; then
  while IFS= read -r hid; do
    [[ -z "$hid" ]] && continue
    case "$hid" in
      commitizen)            add_hook commit_msg commitizen; add_hook commit_msg conventional-commits ;;
      ruff|ruff-format|pyflakes|mypy|black|eslint|prettier|gofmt|go-vet|golangci-lint|fmt|clippy|trailing-whitespace)
                              add_hook pre_commit "$hid" ;;
      gitleaks)              add_hook pre_commit gitleaks ;;
      block-main)            add_hook pre_commit block-main ;;
    esac
  done < "$precommit_dump"
fi

# Native .git/hooks (unknown-stack path): presence of nyann markers →
# core block-main + commit-msg.
if [[ -f "$target/.git/hooks/pre-commit" ]] && grep -Fq 'nyann-managed-hook' "$target/.git/hooks/pre-commit"; then
  add_hook pre_commit block-main
  add_hook pre_commit gitleaks
fi
if [[ -f "$target/.git/hooks/commit-msg" ]] && grep -Fq 'nyann-managed-hook' "$target/.git/hooks/commit-msg"; then
  add_hook commit_msg conventional-commits
fi

# --- commit convention ------------------------------------------------------
# Scan last 50 commit subjects. Score:
#   CC regex hit   → +1
#   autogenerated (Merge / Revert / fixup)  → not counted
#   anything else  → +1 miss

cc_regex='^(feat|fix|chore|docs|refactor|test|perf|ci|build|style|revert)(\([^)]+\))?!?: .+'
commit_hits=0
commit_misses=0

if [[ -d "$target/.git" ]] && git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
  while IFS= read -r subj; do
    [[ -z "$subj" ]] && continue
    case "$subj" in
      "Merge "*|"Revert "*|"fixup! "*|"squash! "*|"amend! "*) continue ;;
    esac
    if [[ "$subj" =~ $cc_regex ]]; then
      commit_hits=$((commit_hits + 1))
    else
      commit_misses=$((commit_misses + 1))
    fi
  # `--pretty=tformat:%s` terminates each entry with a newline (unlike
  # format: which uses separator-only). Without this, a single-commit repo
  # produces zero lines for `read`.
  done < <(git -C "$target" log -n 50 --pretty=tformat:'%s' 2>/dev/null)
fi

total=$((commit_hits + commit_misses))
conv_ratio=0
if (( total > 0 )); then
  # Integer percentage, good enough for confidence thresholds.
  conv_ratio=$(( 100 * commit_hits / total ))
fi

conv_format='"unknown"'
if (( total == 0 )); then
  conv_format='"conventional-commits"'   # default when we can't look
elif (( conv_ratio >= 80 )); then
  conv_format='"conventional-commits"'
elif (( conv_ratio < 40 )); then
  conv_format='"unknown"'
else
  conv_format='"unknown"'  # mixed → user's call
fi

# --- branching strategy -----------------------------------------------------

has_develop=false
has_semver_tag=false
has_release_branch=false

if [[ -d "$target/.git" ]]; then
  git -C "$target" rev-parse --verify develop >/dev/null 2>&1 && has_develop=true
  if git -C "$target" tag --list 2>/dev/null | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+'; then
    has_semver_tag=true
  fi
  if git -C "$target" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -qE '^release/'; then
    has_release_branch=true
  fi
fi

branching_strategy="github-flow"
branching_inferred=true
if $has_develop && ($has_semver_tag || $has_release_branch); then
  branching_strategy="gitflow"
elif $has_semver_tag; then
  branching_strategy="gitflow"  # weaker signal but still library-ish
fi

# --- extras -----------------------------------------------------------------

extras_json='{}'
[[ -f "$target/.gitignore"      ]] && extras_json=$(jq '. + {gitignore: true}'      <<<"$extras_json")
[[ -f "$target/.editorconfig"   ]] && extras_json=$(jq '. + {editorconfig: true}'   <<<"$extras_json")
[[ -f "$target/CLAUDE.md"       ]] && extras_json=$(jq '. + {claude_md: true}'      <<<"$extras_json")

# Detect CI workflows. The flag goes into both extras.github_actions_ci
# (legacy/discovery field) AND ci.enabled (the field bootstrap.sh and
# switch-profile.sh actually gate generation on). Setting only the
# extras flag was the bug — learned profiles silently skipped CI
# regeneration on apply because the consumer's gate was never tripped.
ci_block='{"enabled": false}'
if [[ -d "$target/.github/workflows" ]]; then
  extras_json=$(jq '. + {github_actions_ci: true}' <<<"$extras_json")
  ci_block='{"enabled": true}'
fi

# --- documentation block ----------------------------------------------------

scaffold_types='[]'
[[ -f "$target/docs/architecture.md" ]] && scaffold_types=$(jq '. + ["architecture"]' <<<"$scaffold_types")
[[ -f "$target/docs/prd.md"          ]] && scaffold_types=$(jq '. + ["prd"]'          <<<"$scaffold_types")
[[ -d "$target/docs/decisions"       ]] && scaffold_types=$(jq '. + ["adrs"]'         <<<"$scaffold_types")
[[ -d "$target/docs/research"        ]] && scaffold_types=$(jq '. + ["research"]'     <<<"$scaffold_types")

# --- assemble + validate + save ---------------------------------------------

profile_json=$(jq -n \
  --arg name "$profile_name" \
  --arg primary_language "$primary_language" \
  --argjson framework "$framework" \
  --argjson package_manager "$package_manager" \
  --arg branching_strategy "$branching_strategy" \
  --argjson pre_commit "$pre_commit_list" \
  --argjson commit_msg "$commit_msg_list" \
  --argjson pre_push "$pre_push_list" \
  --argjson extras "$extras_json" \
  --argjson ci "$ci_block" \
  --argjson conv_format "$conv_format" \
  --argjson scaffold_types "$scaffold_types" \
  '
  {
    "$schema": "https://nyann.dev/schemas/profile/v1.json",
    "name": $name,
    "description": ("Learned from a reference repo on " + (now | todate)),
    "schemaVersion": 1,
    "stack": {
      "primary_language": $primary_language,
      "framework": $framework,
      "package_manager": $package_manager
    },
    "branching": {
      "strategy": $branching_strategy,
      "base_branches": ["main"],
      "branch_name_patterns": {
        "feature": "feat/{slug}",
        "bugfix":  "fix/{slug}"
      }
    },
    "hooks": {
      "pre_commit": $pre_commit,
      "commit_msg": $commit_msg,
      "pre_push":   $pre_push
    },
    "extras": $extras,
    "ci": $ci,
    "conventions": {
      "commit_format": $conv_format
    },
    "documentation": {
      "scaffold_types": $scaffold_types,
      "storage_strategy": "local",
      "adr_format": "madr",
      "claude_md_mode": "router",
      "claude_md_size_budget_kb": 3
    }
  }
  ' )

# Validate via bin/validate-profile.sh. Write to a temp first so failed
# validation doesn't leave garbage at the final path.
mkdir -p "$user_root/profiles"
tmp_out=$(mktemp -t nyann-learn-out.XXXXXX)
printf '%s\n' "$profile_json" > "$tmp_out"

if ! "${_script_dir}/validate-profile.sh" "$tmp_out" >/dev/null 2>&1; then
  nyann::warn "assembled profile failed schema validation. Output kept at $tmp_out for inspection."
  exit 2
fi

out_path="$user_root/profiles/${profile_name}.json"
mv "$tmp_out" "$out_path"
nyann::log "wrote $out_path"

# Emit a one-line confidence summary so the caller knows which bits were
# inferred vs. known.
nyann::log "confidence: commit ${conv_ratio}% CC / branching=${branching_strategy} (inferred=${branching_inferred})"

if $to_stdout; then
  cat "$out_path"
fi
