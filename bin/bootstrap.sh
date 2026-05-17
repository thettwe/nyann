#!/usr/bin/env bash
# bootstrap.sh — execute a confirmed ActionPlan against a target repo.
#
# Usage:
#   bootstrap.sh --target <repo>
#                --plan <confirmed-plan.json>
#                --profile <path>
#                --doc-plan <path>
#                --stack <path>
#                [--project-name <name>]
#                [--dry-run]
#                [--source bootstrap|retrofit]   # boot record provenance label
#
# The plan is assumed to be already previewed and confirmed (the skill layer
# drives preview.sh). bootstrap.sh reads it, then walks each write + command
# in order. On any step failure, aborts cleanly and reports which step and
# which command failed. Idempotent — every sub-step checks before mutating.
#
# Emits a structured JSON summary to stdout on completion. Log lines go
# to stderr.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
plan_path=""
profile_path=""
doc_plan_path=""
stack_path=""
project_name=""
dry_run=false
expected_plan_sha256=""
boot_record_source="bootstrap"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         target="${2:-}"; shift 2 ;;
    --target=*)       target="${1#--target=}"; shift ;;
    --plan)           plan_path="${2:-}"; shift 2 ;;
    --plan=*)         plan_path="${1#--plan=}"; shift ;;
    --plan-sha256)    expected_plan_sha256="${2:-}"; shift 2 ;;
    --plan-sha256=*)  expected_plan_sha256="${1#--plan-sha256=}"; shift ;;
    --profile)        profile_path="${2:-}"; shift 2 ;;
    --profile=*)      profile_path="${1#--profile=}"; shift ;;
    --doc-plan)       doc_plan_path="${2:-}"; shift 2 ;;
    --doc-plan=*)     doc_plan_path="${1#--doc-plan=}"; shift ;;
    --stack)          stack_path="${2:-}"; shift 2 ;;
    --stack=*)        stack_path="${1#--stack=}"; shift ;;
    --project-name)   project_name="${2:-}"; shift 2 ;;
    --project-name=*) project_name="${1#--project-name=}"; shift ;;
    --dry-run)        dry_run=true; shift ;;
    --source)         boot_record_source="${2:-}"; shift 2 ;;
    --source=*)       boot_record_source="${1#--source=}"; shift ;;
    -h|--help)        sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target is required and must be a directory"
target="$(cd "$target" && pwd)"
[[ -n "$plan_path" && -f "$plan_path" ]] || nyann::die "--plan <path> is required"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
[[ -n "$doc_plan_path" && -f "$doc_plan_path" ]] || nyann::die "--doc-plan <path> is required"

# Preview→execute integrity binding. The caller MUST pass --plan-sha256
# (computed via `bin/preview.sh --emit-sha256`) so we can recompute the
# canonical SHA-256 of the plan file right now and refuse to run on
# mismatch. That closes the TOCTOU window where a malicious (or merely
# concurrent) process could rewrite the plan between the user's "yes"
# in preview.sh and bootstrap's first jq read. CLAUDE.md spells this
# out as a non-negotiable for orchestrators that hand-build an
# ActionPlan; we enforce it at the script level so an orchestrator
# that forgets to pass it can't silently bypass the binding.
# Normalization matches preview.sh — jq -Sc sorts keys and strips
# whitespace.
[[ -n "$expected_plan_sha256" ]] \
  || nyann::die "--plan-sha256 is required (compute via 'bin/preview.sh --plan <path> --emit-sha256'). The integrity binding closes the TOCTOU window between preview and execute; bootstrap refuses to run without it."
if ! [[ "$expected_plan_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
  nyann::die "--plan-sha256 must be 64 hex characters"
fi
plan_canon=$(jq -Sc . "$plan_path") \
  || nyann::die "failed to canonicalise plan for integrity check: $plan_path"
if command -v shasum >/dev/null 2>&1; then
  actual_plan_sha256=$(printf '%s' "$plan_canon" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  actual_plan_sha256=$(printf '%s' "$plan_canon" | sha256sum | awk '{print $1}')
else
  nyann::die "neither shasum nor sha256sum on PATH — cannot verify --plan-sha256"
fi
# Case-insensitive hex compare.
expected_lc=$(printf '%s' "$expected_plan_sha256" | tr 'A-F' 'a-f')
actual_lc=$(printf '%s'   "$actual_plan_sha256"   | tr 'A-F' 'a-f')
if [[ "$expected_lc" != "$actual_lc" ]]; then
  nyann::die "plan integrity check failed: expected SHA-256 $expected_lc, computed $actual_lc. The plan file changed between preview and execute — rerun preview.sh and pass its new SHA-256."
fi

# --- remote[] gate ----------------------------------------------------------
# preview.sh renders ActionPlan.remote[] entries (branch protection rules,
# remote mutations) and the schema declares them executable, but bootstrap
# has no dispatcher for them yet — no GitHub-API path, no enforcement
# helper. If a caller hands in a non-empty remote[], silently dropping it
# would lie to preview-before-mutate (the user saw the rules in preview
# and now they aren't being applied). Refuse the plan instead so the
# caller is forced to either remove the entries or implement the
# dispatcher. gh-integration.sh remains the sanctioned tool for branch
# protection until that work lands.
remote_count=$(jq -r '.remote | length' "$plan_path")
if [[ "$remote_count" -gt 0 ]]; then
  nyann::die "ActionPlan.remote[] has $remote_count entr$( ((remote_count == 1)) && echo y || echo ies ), but bootstrap has no remote dispatcher. The user saw these in preview; silently dropping them would break preview-before-mutate. Use bin/gh-integration.sh for branch protection, and clear remote[] from the plan."
fi

# --- profile/stack sanity check ---------------------------------------------
# If the caller passed both a stack descriptor and a profile, warn (don't
# fail) when the profile's stack.primary_language disagrees with detection.
# Common case: user invokes bootstrap with --profile default on a confidently-
# detected repo, missing the stack-specific hook bundle. Emitting the warning
# on stderr means the skill layer can catch + relay it; bootstrap still runs.
if [[ -n "$stack_path" && -f "$stack_path" ]]; then
  profile_lang=$(jq -r '.stack.primary_language // "unknown"' "$profile_path")
  detected_lang=$(jq -r '.primary_language // "unknown"' "$stack_path")
  profile_name_for_msg=$(jq -r '.name // "unnamed"' "$profile_path")
  # Schema enforces name regex, but bootstrap accepts --profile <path>
  # directly, so a hand-crafted profile could inject ANSI escapes into
  # stderr via nyann::warn. Re-validate before interpolating.
  if ! nyann::valid_profile_name "$profile_name_for_msg"; then
    profile_name_for_msg="(invalid-name)"
  fi
  if [[ "$profile_lang" == "unknown" && "$detected_lang" != "unknown" ]]; then
    nyann::warn "profile '$profile_name_for_msg' is stack-agnostic (default) but detection identified $detected_lang — stack-specific hooks will be skipped. Consider re-running with a matching profile."
  elif [[ "$profile_lang" != "unknown" && "$detected_lang" != "unknown" && "$profile_lang" != "$detected_lang" ]]; then
    nyann::warn "profile '$profile_name_for_msg' targets $profile_lang but detection identified $detected_lang — hooks may not match the actual repo."
  fi
fi

summary_writes=0
summary_writes_skipped=0
summary_skipped_records='[]'
summary_branches_created='[]'
summary_claude_md_bytes=0
summary_hook_phases='[]'
summary_boot_record=""
_bootstrap_tmp_files=()

maybe_run() {
  if $dry_run; then
    nyann::log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

# --- boot record initialization ---------------------------------------------
# Records every mutation so bin/undo-bootstrap.sh can reverse this run.
# Skipped in dry-run.
_BR_DRY_RUN="$dry_run"
# shellcheck source=./boot-record.sh
source "${_script_dir}/boot-record.sh"
case "$boot_record_source" in
  bootstrap|retrofit) ;;
  *) nyann::die "--source must be bootstrap|retrofit (got: $boot_record_source)" ;;
esac
nyann::br_init "$target" "$boot_record_source" "$profile_path" "$plan_path"
# Finalize the manifest on any exit path so partial runs are still
# undoable. Runs before the existing _bootstrap_cleanup trap (last-set
# wins) — we chain explicitly.
trap '_bootstrap_finalize_record' EXIT

_bootstrap_finalize_record() {
  if [[ "${_BR_ACTIVE:-false}" == "true" ]]; then
    # Capture finalize stderr so we can surface real failures (jq error,
    # disk full, permission). Previously suppressed unconditionally,
    # which masked real failures and left the operator with a silent
    # `boot_record: null` and no clue why.
    local _br_err
    _br_err=$(mktemp -t nyann-br-finalize.XXXXXX 2>/dev/null || echo "/dev/null")
    summary_boot_record=$(nyann::br_finalize 2>"$_br_err" || true)
    if [[ -z "$summary_boot_record" && -s "$_br_err" ]]; then
      cat "$_br_err" >&2
    fi
    [[ "$_br_err" != "/dev/null" ]] && rm -f "$_br_err"
  fi
  # Chain the original cleanup if it has been registered by step 4.
  if declare -F _bootstrap_cleanup >/dev/null 2>&1; then
    _bootstrap_cleanup
  fi
}

# --- step 1: git init if missing --------------------------------------------

if [[ ! -d "$target/.git" ]]; then
  maybe_run git -C "$target" init -q -b main
  nyann::br_action_git_init
  nyann::log "git init: $target"
fi

# --- step 2: create branches per profile branching ---------------------------

strategy=$(jq -r '.branching.strategy // "github-flow"' "$profile_path")
base_branches_json=$(jq '.branching.base_branches // ["main"]' "$profile_path")
long_lived_json='[]'
case "$strategy" in
  gitflow)
    long_lived_json='["develop"]'
    ;;
esac

create_branch_if_missing() {
  local b="$1"
  if git -C "$target" rev-parse --verify "$b" >/dev/null 2>&1; then
    nyann::log "branch exists: $b"
    return 0
  fi
  # git branch from the initial HEAD. If there are no commits yet, we can't
  # create a branch — make an empty seed commit first.
  #
  # Prefer the repo's (or user's) configured git identity over the
  # hardcoded nyann identity. Only fall back to nyann@local when
  # nothing is configured — e.g. clean CI runners.
  if ! git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
    nyann::resolve_identity "$target"
    maybe_run git -C "$target" \
      -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
      commit -q --allow-empty -m "chore: seed repo (nyann bootstrap)" \
      --author="$NYANN_GIT_NAME <$NYANN_GIT_EMAIL>"
    if ! $dry_run; then
      _seed_sha=$(git -C "$target" rev-parse HEAD 2>/dev/null || true)
      [[ -n "$_seed_sha" ]] && nyann::br_action_seed_commit "$_seed_sha"
    fi
  fi
  maybe_run git -C "$target" branch -- "$b"
  summary_branches_created=$(jq --arg b "$b" '. + [$b]' <<<"$summary_branches_created")
  if ! $dry_run; then
    _branch_base=$(git -C "$target" rev-parse "$b" 2>/dev/null || true)
    [[ -n "$_branch_base" ]] && nyann::br_action_branch "$b" "$_branch_base"
  fi
  nyann::log "branch created: $b"
}

# Ensure main (or the first base branch) exists as a real ref. A fresh
# `git init -b main` with no commits has an unresolvable HEAD; doctor and
# downstream consumers need `rev-parse --verify main` to succeed. Make an
# empty seed commit when no HEAD exists, then rename the current branch
# to match the profile's first base branch.
first_base=$(jq -r '.[0]' <<<"$base_branches_json")

if ! git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
  # Same configured-identity-first strategy as above.
  nyann::resolve_identity "$target"
  maybe_run git -C "$target" \
    -c "user.email=$NYANN_GIT_EMAIL" -c "user.name=$NYANN_GIT_NAME" \
    commit -q --allow-empty -m "chore: seed repo (nyann bootstrap)" \
    --author="$NYANN_GIT_NAME <$NYANN_GIT_EMAIL>"
  if ! $dry_run; then
    _seed_sha=$(git -C "$target" rev-parse HEAD 2>/dev/null || true)
    [[ -n "$_seed_sha" ]] && nyann::br_action_seed_commit "$_seed_sha"
  fi
fi

if ! git -C "$target" rev-parse --verify "$first_base" >/dev/null 2>&1; then
  current=$(git -C "$target" branch --show-current 2>/dev/null || true)
  if [[ -n "$current" && "$current" != "$first_base" ]]; then
    maybe_run git -C "$target" branch -M -- "$first_base"
    nyann::br_action_default_rename "$current" "$first_base"
  fi
fi

# Long-lived branches (gitflow: develop).
while IFS= read -r b; do
  create_branch_if_missing "$b"
done < <(jq -r '.[]' <<<"$long_lived_json")

# --- step 2b: pre-mutation snapshot ------------------------------------------
# Walk plan.writes[] and snapshot the pre-state of every declared path,
# plus the well-known hook side-effect paths that subsystems mutate
# without enumerating in writes[]. br_finalize_writes diffs current vs
# pre-state at the end and emits the resulting write actions.
_br_category_for() {
  case "$1" in
    .gitignore|*/.gitignore)             echo "gitignore" ;;
    .editorconfig|*/.editorconfig)       echo "editorconfig" ;;
    CLAUDE.md|docs/*|memory/*|*/docs/*|*/memory/*)
                                         echo "docs" ;;
    .github/*)                           echo "github" ;;
    .git/hooks/*|.husky/*|.pre-commit-config.yaml|package.json|Cargo.toml|lefthook.yml)
                                         echo "hooks" ;;
    *)                                   echo "docs" ;;
  esac
}

while IFS=$'\t' read -r p a; do
  [[ -z "$p" ]] && continue
  cat=$(_br_category_for "$p")
  nyann::br_snapshot "$cat" "$p" "$a"
done < <(jq -r '.writes[]? | [.path, (.action // "")] | @tsv' "$plan_path")

# Hook subsystems write outside the plan (.git/hooks/, .husky/, package.json
# husky/lint-staged keys). Snapshot the well-known set so undo can reverse.
nyann::br_snapshot_dir hooks ".git/hooks"
nyann::br_snapshot_dir hooks ".husky"
nyann::br_snapshot hooks ".pre-commit-config.yaml"
nyann::br_snapshot hooks "package.json"
nyann::br_snapshot hooks "Cargo.toml"
nyann::br_snapshot hooks "lefthook.yml"
# Register the hook directories for post-mutation diff. Snapshot above
# only catches files that existed pre-bootstrap; install-hooks materialises
# .git/hooks/pre-commit, .husky/pre-commit, etc. on a fresh repo, so
# br_finalize_writes scans these dirs at finalize time and emits create
# actions for any newly-present files.
nyann::br_register_post_dir hooks ".git/hooks"
nyann::br_register_post_dir hooks ".husky"

# --- step 3: plan writes (create / merge / overwrite) ------------------------
# NOTE: bootstrap.sh is a dispatcher; file content is produced by specialized
# scripts (scaffold-docs, gen-claudemd, install-hooks, gitignore-combiner).
# Plan writes are the non-specialized ones — usually empty in v1 because the
# specialized scripts do their own idempotent writes. Counted for the summary.

while IFS= read -r w; do
  p=$(jq -r '.path' <<<"$w")
  a=$(jq -r '.action' <<<"$w")
  # Reject empty / absolute / traversal paths *before* concatenating
  # with $target — otherwise a plan containing `"path": "../escape"`
  # (or an absolute `/etc/...`) would let `rm -rf -- "$full"` hit
  # files outside the repo. preview.sh prints paths but doesn't
  # canonicalise them, so the user can't visually catch this.
  if [[ -z "$p" || "$p" == /* || "$p" == *".."* ]]; then
    nyann::die "plan write path rejected (empty, absolute, or contains '..'): $p"
  fi
  full=$(nyann::assert_path_under_target "$target" "$target/$p" "plan write path '$p'")
  case "$a" in
    create|merge|overwrite)
      if [[ -e "$full" && "$a" == "create" ]]; then
        summary_writes_skipped=$((summary_writes_skipped + 1))
        nyann::log "skip (exists): $p"
        continue
      fi
      # bootstrap doesn't know how to materialize arbitrary content; downstream
      # scripts do. If a write has .diff or .body we could apply; in v1 we
      # just log.
      nyann::log "plan write: $a $p (delegated to subsystem)"
      summary_writes=$((summary_writes + 1))
      ;;
    delete)
      if [[ -e "$full" ]]; then
        maybe_run rm -rf -- "$full"
        nyann::log "delete: $p"
      fi
      ;;
    *) nyann::warn "unknown write action '$a' for $p — skipping" ;;
  esac
done < <(jq -c '.writes[]?' "$plan_path")

# --- step 4: gitignore combiner ---------------------------------------------
# Inferred from stack: JS/TS → jsts, Python → python, mixed → both. Always
# safe to run; combiner is idempotent.

gitignore_templates=""
if [[ -n "$stack_path" && -f "$stack_path" ]]; then
  pl=$(jq -r '.primary_language // "unknown"' "$stack_path")
  sl=$(jq -r '.secondary_languages // [] | join(",")' "$stack_path")
  case "$pl" in
    typescript|javascript) gitignore_templates="jsts" ;;
    python)                gitignore_templates="python" ;;
    go)                    gitignore_templates="go" ;;
    rust)                  gitignore_templates="rust" ;;
    *)                     gitignore_templates="generic" ;;
  esac
  # Fold secondary-language templates in if not already the primary.
  for sec in jsts python go rust; do
    case "$sec" in
      jsts)   [[ "$sl" == *"typescript"* || "$sl" == *"javascript"* ]] || continue ;;
      python) [[ "$sl" == *"python"* ]] || continue ;;
      go)     [[ "$sl" == *"go"* ]] || continue ;;
      rust)   [[ "$sl" == *"rust"* ]] || continue ;;
    esac
    case ",${gitignore_templates}," in
      *",${sec},"*) ;;
      *) gitignore_templates="${gitignore_templates},${sec}" ;;
    esac
  done
fi
if [[ -n "$gitignore_templates" ]]; then
  # When the plan carries a preview_blob for .gitignore (rendered via
  # bin/render-plan.sh during preview), execute from that blob instead
  # of re-running the combiner. This is the only way to guarantee the
  # bytes the user approved in preview match the bytes that land on
  # disk — re-rendering against live repo state opens a TOCTOU window
  # where a concurrent edit between preview and execute changes the
  # merge output without changing the plan SHA.
  gi_blob=$(jq -r '
    [.writes[]? | select(.path == ".gitignore" and (.preview_blob // "") != "")][0].preview_blob // ""
  ' "$plan_path")
  if [[ -n "$gi_blob" && -f "$gi_blob" ]]; then
    nyann::log "using preview_blob for .gitignore: $gi_blob"
    maybe_run cp -- "$gi_blob" "$target/.gitignore"
  else
    maybe_run "${_script_dir}/gitignore-combiner.sh" --target "$target/.gitignore" --templates "$gitignore_templates"
  fi
fi


_bootstrap_cleanup() { rm -f ${_bootstrap_tmp_files[@]+"${_bootstrap_tmp_files[@]}"} 2>/dev/null || true; }
# Trap is registered at the top of the script alongside boot-record finalize;
# _bootstrap_finalize_record chains _bootstrap_cleanup if it has been defined.

# --- step 4b: editorconfig --------------------------------------------------
# Write a minimal .editorconfig when profile.extras.editorconfig=true AND
# the plan's writes[] explicitly declares it. Silently writing without a
# plan entry bypasses preview-before-mutate (user never saw the file in
# the diff they confirmed), so require the skill to surface it in the
# plan it composed.
editorconfig_wanted=$(jq -r '.extras.editorconfig // false' "$profile_path")
editorconfig_in_plan=$(jq -r '[.writes[]? | select(.path == ".editorconfig")] | length' "$plan_path")

if [[ "$editorconfig_wanted" == "true" ]] && [[ "$editorconfig_in_plan" == "0" ]]; then
  nyann::warn "profile.extras.editorconfig=true but .editorconfig is not in the ActionPlan's writes[] — skipping (plan-builder should include it)"
fi

if [[ "$editorconfig_wanted" == "true" ]] \
   && [[ "$editorconfig_in_plan" != "0" ]] \
   && [[ ! -e "$target/.editorconfig" ]]; then
  if ! $dry_run; then
    [[ -L "$target/.editorconfig" ]] && nyann::die "refusing to write .editorconfig via symlink: $target/.editorconfig"
    ec_tmp=$(mktemp -t nyann-editorconfig.XXXXXX)
    _bootstrap_tmp_files+=("$ec_tmp")
    cat > "$ec_tmp" <<'EC'
# nyann-managed — .editorconfig
# Shared editor baseline. Remove this file to opt out of nyann's default.
root = true

[*]
indent_style = space
indent_size = 2
end_of_line = lf
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.{md,markdown}]
trim_trailing_whitespace = false

[Makefile]
indent_style = tab
EC
    mv "$ec_tmp" "$target/.editorconfig"
    nyann::log "wrote $target/.editorconfig"
  fi
fi

# --- step 4c: resolve workspace configs (monorepo support) ------------------
# Must run before scaffold-docs (step 5) so the doc scaffolder can read
# per-workspace documentation settings. Also feeds per-workspace gitignore
# (5b), CI matrix (5c), CODEOWNERS, and the CLAUDE.md router.

ws_configs_file=""
ws_scopes_file=""

is_monorepo=false
if [[ -n "$stack_path" && -f "$stack_path" ]]; then
  is_monorepo=$(jq -r '.is_monorepo // false' "$stack_path")
fi

if [[ "$is_monorepo" == "true" ]]; then
  ws_configs_file=$(mktemp -t nyann-ws-configs.XXXXXX)
  _bootstrap_tmp_files+=("$ws_configs_file")
  ws_scopes_file=$(mktemp -t nyann-ws-scopes.XXXXXX)
  _bootstrap_tmp_files+=("$ws_scopes_file")
  # resolve-workspace-configs.sh merges detected workspaces with profile overrides.
  "${_script_dir}/resolve-workspace-configs.sh" \
    --stack "$stack_path" --profile "$profile_path" > "$ws_configs_file" 2>/dev/null

  # Extract workspace basenames as commit scopes, merge with profile scopes.
  profile_scopes=$(jq -c '.conventions.commit_scopes // []' "$profile_path")
  ws_basenames=$(jq -c '[.[].path | split("/") | last]' "$ws_configs_file")
  jq -c --argjson ps "$profile_scopes" '. + $ps | unique' <<<"$ws_basenames" > "$ws_scopes_file"

  nyann::log "monorepo: resolved $(jq 'length' "$ws_configs_file") workspace config(s), $(jq 'length' "$ws_scopes_file") commit scope(s)"
fi

# --- step 5: doc scaffolder --------------------------------------------------
# preview-before-mutate: only invoke scaffold-docs when the ActionPlan
# declares at least one doc write. scaffold-docs creates docs/*.md,
# memory/README.md, ADRs, etc.; if the skill layer didn't surface those
# in `writes[]`, the user never saw them in the preview and we refuse
# to silently materialise files behind their back. Warn (not die) so an
# intentional plan-without-docs run stays usable.

docs_in_plan=$(jq -r '
  [.writes[]? | select(
    (.path | startswith("docs/")) or
    (.path | startswith("memory/")) or
    (.path == "docs" or .path == "memory") or
    (.path | test("(^|/)docs/")) or
    (.path | test("(^|/)memory/"))
  )] | length
' "$plan_path")

if [[ "$docs_in_plan" == "0" ]]; then
  nyann::warn "skipping scaffold-docs: the ActionPlan's writes[] contains no docs/ or memory/ entries (root-level or workspace-nested) — plan-builder must enumerate scaffolded files for preview-before-mutate"
else
  # v1.7.0 — read documentation.glossary settings from the profile so
  # scaffold-docs can drive scaffold-glossary when opted in. Default
  # auto_populate=false preserves v1.6.0 behaviour for existing users.
  glossary_args=()
  if [[ "$(jq -r '.documentation.glossary.auto_populate // false' "$profile_path")" == "true" ]]; then
    glossary_args+=(--auto-glossary)
    gmt=$(jq -r '.documentation.glossary.max_terms // 50' "$profile_path")
    glossary_args+=(--glossary-max-terms "$gmt")
    glang=$(jq -r '(.documentation.glossary.languages // ["auto"]) | join(",")' "$profile_path")
    glossary_args+=(--glossary-languages "$glang")
  fi

  # Build a newline-delimited allow-list of approved write paths from the
  # ActionPlan. When the workspace-doc loop runs inside scaffold-docs.sh, it
  # gates each workspace doc target against this set — defends against
  # planner/executor drift (Codex review #1 follow-up). The list is the
  # same plan.writes[] paths bootstrap.sh's snapshot loop iterates, so any
  # workspace doc that wasn't pre-enumerated by plan-bootstrap.sh gets
  # skipped + warned instead of silently materialised behind the preview.
  _allowed_writes_file=""
  if [[ -n "$ws_configs_file" ]]; then
    _allowed_writes_file=$(mktemp -t nyann-allowed-writes.XXXXXX)
    _bootstrap_tmp_files+=("$_allowed_writes_file")
    jq -r '[.writes[]?.path] | unique | .[]' "$plan_path" > "$_allowed_writes_file"
  fi

  maybe_run "${_script_dir}/scaffold-docs.sh" \
    --plan "$doc_plan_path" \
    ${stack_path:+--stack "$stack_path"} \
    ${project_name:+--project-name "$project_name"} \
    --target "$target" \
    ${ws_configs_file:+--workspace-configs "$ws_configs_file"} \
    ${_allowed_writes_file:+--allowed-writes "$_allowed_writes_file"} \
    ${glossary_args[@]+"${glossary_args[@]}"}
fi

# --- step 5b: per-workspace gitignore (monorepo) ---------------------------
# When workspace configs declare extras.gitignore=true AND a workspace profile
# is set, write a workspace-local .gitignore from the workspace language's
# template. This gives Flutter workspaces .gitignore rules for .dart_tool/,
# Node workspaces for node_modules/, etc.
#
# Each workspace .gitignore must appear in plan.writes[] before being
# written — that's what plan-bootstrap.sh enumerates for monorepos.
# A workspace .gitignore that wasn't in the preview gets skipped +
# warned, never silently materialised (preview-before-mutate).

if [[ -n "${ws_configs_file:-}" && -f "${ws_configs_file:-}" ]]; then
  ws_gi_count=$(jq '[.[] | select(.extras.gitignore == true)] | length' "$ws_configs_file")
  if (( ws_gi_count > 0 )); then
    # Pre-build the set of planned write paths once for O(1) lookup per
    # workspace. Using a newline-delimited string + grep -Fxq because we
    # need exact-line match without bash 4 associative arrays.
    _planned_writes=$(jq -r '[.writes[]?.path] | unique | .[]' "$plan_path")

    while IFS=$'\t' read -r ws_path ws_lang; do
      [[ -z "$ws_path" ]] && continue
      ws_gi_rel="${ws_path}/.gitignore"
      if ! grep -Fxq "$ws_gi_rel" <<<"$_planned_writes"; then
        nyann::warn "skipping workspace gitignore: $ws_gi_rel not in ActionPlan.writes[] (plan-builder must enumerate it for preview-before-mutate)"
        continue
      fi

      local_template=""
      case "$ws_lang" in
        typescript|javascript) local_template="jsts" ;;
        python)                local_template="python" ;;
        go)                    local_template="go" ;;
        rust)                  local_template="rust" ;;
        dart)                  local_template="dart" ;;
        swift)                 local_template="swift" ;;
        kotlin|java)           local_template="jvm" ;;
        *)                     local_template="generic" ;;
      esac
      ws_gi_target="$target/$ws_gi_rel"
      if [[ -n "$local_template" ]]; then
        maybe_run "${_script_dir}/gitignore-combiner.sh" --target "$ws_gi_target" --templates "$local_template"
        nyann::log "wrote workspace gitignore: $ws_gi_rel ($local_template)"
      fi
    done < <(jq -r '.[] | select(.extras.gitignore == true) | [.path, .primary_language] | @tsv' "$ws_configs_file")
  fi
fi

# --- step 5c: CI workflow generation -----------------------------------------
# Generate .github/workflows/ci.yml when profile.ci.enabled=true AND the
# plan declares the file. Same preview-before-mutate gate as everywhere else.

ci_enabled=$(jq -r '.ci.enabled // false' "$profile_path")
ci_in_plan=$(jq -r '[.writes[]? | select(.path == ".github/workflows/ci.yml")] | length' "$plan_path")
ci_ws_in_plan=$(jq -r '[.writes[]? | select(.path == ".github/workflows/ci-workspaces.yml")] | length' "$plan_path")

if [[ "$ci_enabled" == "true" ]]; then
  if [[ "$ci_in_plan" == "0" ]]; then
    nyann::warn "skipping gen-ci: .github/workflows/ci.yml is not in the ActionPlan's writes[] (plan-builder must surface it for preview-before-mutate)"
  elif [[ -n "$stack_path" && -f "$stack_path" ]]; then
    _gen_ci_args=(--profile "$profile_path" --stack "$stack_path" --target "$target")
    if [[ -n "${ws_configs_file:-}" && -f "${ws_configs_file:-}" ]]; then
      if [[ "$ci_ws_in_plan" == "0" ]]; then
        nyann::warn "skipping workspace CI matrix: .github/workflows/ci-workspaces.yml is not in the ActionPlan's writes[]"
      else
        _gen_ci_args+=(--workspace-configs "$ws_configs_file")
      fi
    fi
    maybe_run "${_script_dir}/gen-ci.sh" "${_gen_ci_args[@]}"
  else
    nyann::warn "skipping gen-ci: no stack descriptor available"
  fi
fi

# --- step 5d: GitHub templates (PR + issue) ----------------------------------
# Generate .github/ templates when profile.extras.github_templates=true AND
# the plan declares the PR template file.

github_templates_wanted=$(jq -r '.extras.github_templates // false' "$profile_path")
pr_template_in_plan=$(jq -r '[.writes[]? | select(.path == ".github/PULL_REQUEST_TEMPLATE.md")] | length' "$plan_path")

if [[ "$github_templates_wanted" == "true" ]]; then
  if [[ "$pr_template_in_plan" == "0" ]]; then
    nyann::warn "skipping gen-templates: .github/PULL_REQUEST_TEMPLATE.md is not in the ActionPlan's writes[] (plan-builder must surface it for preview-before-mutate)"
  else
    maybe_run "${_script_dir}/gen-templates.sh" \
      --profile "$profile_path" \
      ${stack_path:+--stack "$stack_path"} \
      --target "$target"
  fi
fi

# --- step 5e: CODEOWNERS (monorepo only) -------------------------------------
# Generate .github/CODEOWNERS when workspace configs exist. Non-monorepo
# repos are silently skipped by gen-codeowners.sh itself.

if [[ -n "$ws_configs_file" && -f "$ws_configs_file" ]]; then
  maybe_run "${_script_dir}/gen-codeowners.sh" \
    --workspace-configs "$ws_configs_file" \
    --target "$target"
fi

# --- step 6: hook installer --------------------------------------------------

hook_phases=(--core)
detected_lang_for_hooks=""
if [[ -n "$stack_path" && -f "$stack_path" ]]; then
  detected_lang_for_hooks=$(jq -r '.primary_language' "$stack_path")
  case "$detected_lang_for_hooks" in
    typescript|javascript) hook_phases+=(--jsts) ;;
    python)                hook_phases+=(--python) ;;
    go)                    hook_phases+=(--go) ;;
    rust)                  hook_phases+=(--rust) ;;
  esac
fi

hook_extra_args=()
if [[ -n "$ws_configs_file" && -f "$ws_configs_file" ]]; then
  hook_extra_args+=(--workspace-configs "$ws_configs_file")
fi
if [[ -n "$ws_scopes_file" && -f "$ws_scopes_file" ]]; then
  hook_extra_args+=(--commit-scopes "$ws_scopes_file")
fi

# Pre-push phase. Auto-enable when profile.hooks.pre_push[] is non-empty.
# The stack-derived test command is what `tests` resolves to in the
# generated hook script — install-hooks.sh writes a runtime warn if
# `tests` is requested without a command.
pre_push_csv=$(jq -r '.hooks.pre_push // [] | join(",")' "$profile_path")
if [[ -n "$pre_push_csv" ]]; then
  hook_phases+=(--pre-push)
  hook_extra_args+=(--pre-push-hooks "$pre_push_csv")
  # Map detected stack to a sensible default test command for the
  # `tests` ID. Profiles that use `tests` get a working hook; profiles
  # that use other IDs (e.g. gitleaks-full) work regardless.
  case "$detected_lang_for_hooks" in
    typescript|javascript) hook_extra_args+=(--pre-push-test-cmd "npm test") ;;
    python)                hook_extra_args+=(--pre-push-test-cmd "pytest") ;;
    go)                    hook_extra_args+=(--pre-push-test-cmd "go test ./...") ;;
    rust)                  hook_extra_args+=(--pre-push-test-cmd "cargo test") ;;
  esac
fi

if $dry_run; then
  nyann::log "DRY-RUN: bin/install-hooks.sh --target $target ${hook_phases[*]} ${hook_extra_args[*]+${hook_extra_args[*]}}"
else
  # install-hooks.sh logs to stderr; JSON skip records land on stdout. Split
  # the two so we can parse skips on stdout and still surface the human log.
  #
  # Stderr was previously captured to a tmp file and dumped at the end via
  # `cat $tmperr >&2`; that turned a 30s-3min install into a silent block
  # followed by a wall of text. Tee stderr to BOTH the user terminal (live
  # progress while pre-commit downloads hook environments) AND the tmp
  # file (so the failure-path dump still works exactly as before).
  # Stdout STAYS captured to a tmp file — it's the JSON-skip-record
  # contract bootstrap.sh consumes; tee'ing it would break the SHA-bound
  # plan execution.
  tmpout=$(mktemp -t nyann-install-out.XXXXXX)
  _bootstrap_tmp_files+=("$tmpout")
  tmperr=$(mktemp -t nyann-install-err.XXXXXX)
  _bootstrap_tmp_files+=("$tmperr")
  if ! "${_script_dir}/install-hooks.sh" --target "$target" "${hook_phases[@]}" ${hook_extra_args[@]+"${hook_extra_args[@]}"} \
         >"$tmpout" 2> >(tee "$tmperr" >&2); then
    rc=$?
    wait   # let tee flush before reading $tmperr (no-op if already done)
    nyann::warn "install-hooks step failed (rc=$rc)"
    # User already saw the stderr live via tee; the dump was the
    # failure-context fallback. Now redundant on the happy "user
    # watched it stream" path, but kept for log-capture / non-tty
    # environments where the tee target wasn't a real terminal.
    cat "$tmperr" >&2 || true
    rm -f "$tmpout" "$tmperr"
    exit $rc
  fi
  # Skip records are JSON objects on stdout; pass them into the summary.
  while IFS= read -r line; do
    if [[ "$line" == \{\"skipped\":* ]]; then
      summary_skipped_records=$(jq --argjson rec "$line" '. + [$rec]' <<<"$summary_skipped_records")
    fi
  done < "$tmpout"
  # Symmetric with the failure branch: ensure the tee process-sub has
  # flushed (so its writes don't race with `rm` and leave the inode
  # alive in /tmp via the open fd). Pure file-leak hygiene — the
  # success path never reads $tmperr.
  wait
  rm -f "$tmpout" "$tmperr"
fi
summary_hook_phases=$(printf '%s\n' "${hook_phases[@]}" | jq -R . | jq -sc .)

# --- step 7: CLAUDE.md router ------------------------------------------------
# preview-before-mutate: same gate as scaffold-docs / editorconfig.
# CLAUDE.md must appear in the ActionPlan's writes[] or we skip it with
# a warning — the user cannot confirm bytes they never saw in preview.

claude_md_in_plan=$(jq -r '[.writes[]? | select(.path == "CLAUDE.md")] | length' "$plan_path")
claude_md_mode=$(jq -r '.documentation.claude_md_mode // "router"' "$profile_path")

if [[ "$claude_md_mode" == "off" ]]; then
  nyann::log "skipping gen-claudemd: profile sets claude_md_mode=off"
elif [[ "$claude_md_in_plan" == "0" ]]; then
  nyann::warn "skipping gen-claudemd: CLAUDE.md is not in the ActionPlan's writes[] (plan-builder must surface it for preview-before-mutate)"
else
  # When the plan carries a preview_blob for CLAUDE.md, the operator
  # already saw the merged bytes in preview. Cp from the blob instead
  # of re-rendering — same TOCTOU rationale as the .gitignore path
  # above.
  cm_blob=$(jq -r '
    [.writes[]? | select(.path == "CLAUDE.md" and (.preview_blob // "") != "")][0].preview_blob // ""
  ' "$plan_path")
  if [[ -n "$cm_blob" && -f "$cm_blob" ]]; then
    nyann::log "using preview_blob for CLAUDE.md: $cm_blob"
    maybe_run cp -- "$cm_blob" "$target/CLAUDE.md"
  else
    claudemd_extra_args=()
    if [[ -n "$ws_configs_file" && -f "$ws_configs_file" ]]; then
      claudemd_extra_args+=(--workspace-configs "$ws_configs_file")
    fi
    if [[ -n "$ws_scopes_file" && -f "$ws_scopes_file" ]]; then
      claudemd_extra_args+=(--extra-scopes "$ws_scopes_file")
    fi

    if [[ -n "$stack_path" ]]; then
      maybe_run "${_script_dir}/gen-claudemd.sh" \
        --profile "$profile_path" \
        --doc-plan "$doc_plan_path" \
        --stack "$stack_path" \
        ${project_name:+--project-name "$project_name"} \
        ${claudemd_extra_args[@]+"${claudemd_extra_args[@]}"} \
        --target "$target"
    else
      maybe_run "${_script_dir}/gen-claudemd.sh" \
        --profile "$profile_path" \
        --doc-plan "$doc_plan_path" \
        ${project_name:+--project-name "$project_name"} \
        ${claudemd_extra_args[@]+"${claudemd_extra_args[@]}"} \
        --target "$target"
    fi
  fi
fi
if [[ -f "$target/CLAUDE.md" ]]; then
  summary_claude_md_bytes=$(wc -c < "$target/CLAUDE.md" | tr -d ' ')
fi

# --- finalize boot record before summary ------------------------------------
# Explicit call so the manifest path lands in the JSON summary; the EXIT
# trap stays as a partial-run safety net (no-op once finalize ran).
# Capture stderr so genuine finalize failures surface to the operator.
if [[ "${_BR_ACTIVE:-false}" == "true" ]]; then
  _br_err=$(mktemp -t nyann-br-finalize.XXXXXX 2>/dev/null || echo "/dev/null")
  summary_boot_record=$(nyann::br_finalize 2>"$_br_err" || true)
  if [[ -z "$summary_boot_record" && -s "$_br_err" ]]; then
    cat "$_br_err" >&2
  fi
  [[ "$_br_err" != "/dev/null" ]] && rm -f "$_br_err"
fi

# --- step 8: summary ---------------------------------------------------------

jq -n \
  --arg target "$target" \
  --arg strategy "$strategy" \
  --argjson branches_created "$summary_branches_created" \
  --argjson writes "$summary_writes" \
  --argjson writes_skipped "$summary_writes_skipped" \
  --argjson hook_phases "$summary_hook_phases" \
  --argjson skipped_records "$summary_skipped_records" \
  --argjson claude_md_bytes "$summary_claude_md_bytes" \
  --argjson dry_run "$dry_run" \
  --arg boot_record "$summary_boot_record" \
  '{
    target: $target,
    strategy: $strategy,
    branches_created: $branches_created,
    writes: $writes,
    writes_skipped: $writes_skipped,
    hook_phases: $hook_phases,
    skipped_records: $skipped_records,
    claude_md_bytes: $claude_md_bytes,
    dry_run: $dry_run,
    boot_record: (if $boot_record == "" then null else $boot_record end)
  }'




nyann::log "bootstrap complete"
