#!/usr/bin/env bash
# scaffold-docs.sh — create local doc + memory structure from a DocumentationPlan.
#
# Usage:
#   scaffold-docs.sh --plan <documentation-plan.json>
#                    [--stack <stack-descriptor.json>]
#                    [--project-name <name>]
#                    [--target <repo-root>]
#
# Behavior (local-only):
# - For each target in the plan whose type == "local", create the file or
#   directory at the mapped path under --target (default cwd).
# - Architecture template is stack-aware: if --stack is provided, {{primary_language}},
#   {{framework}}, {{package_manager}}, and {{is_monorepo}} are filled from it.
# - ADR-000 is always dropped into docs/decisions/ with date filled in.
# - Memory folder is seeded with a README + .gitkeep so the dir travels.
# - Idempotent: existing files are never overwritten. Only gaps get filled.
#
# MCP targets (type != local) are skipped with a note; MCP routing is planned for a future release.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

plan_path=""
stack_path=""
project_name=""
target_root="$PWD"
template_root="${_script_dir}/../templates"
auto_glossary=false
glossary_max_terms=50
glossary_languages="auto"
workspace_configs_path=""
# When set, every workspace-doc write target is checked against this
# newline-delimited list of approved paths before being written. Lets
# bootstrap.sh enforce preview-before-mutate at execution time even
# when scaffold-docs.sh and plan-bootstrap.sh disagree on which paths
# should land in plan.writes[]. When unset, the workspace-doc loop
# writes every scaffold the workspace config declares (back-compat).
allowed_writes_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)            plan_path="${2:-}"; shift 2 ;;
    --plan=*)          plan_path="${1#--plan=}"; shift ;;
    --stack)           stack_path="${2:-}"; shift 2 ;;
    --stack=*)         stack_path="${1#--stack=}"; shift ;;
    --project-name)    project_name="${2:-}"; shift 2 ;;
    --project-name=*)  project_name="${1#--project-name=}"; shift ;;
    --target)          target_root="${2:-}"; shift 2 ;;
    --target=*)        target_root="${1#--target=}"; shift ;;
    --template-root)   template_root="${2:-}"; shift 2 ;;
    --template-root=*) template_root="${1#--template-root=}"; shift ;;
    --auto-glossary)   auto_glossary=true; shift ;;
    --glossary-max-terms)   glossary_max_terms="${2:-50}"; shift 2 ;;
    --glossary-max-terms=*) glossary_max_terms="${1#--glossary-max-terms=}"; shift ;;
    --glossary-languages)   glossary_languages="${2:-auto}"; shift 2 ;;
    --glossary-languages=*) glossary_languages="${1#--glossary-languages=}"; shift ;;
    --workspace-configs)    workspace_configs_path="${2:-}"; shift 2 ;;
    --workspace-configs=*)  workspace_configs_path="${1#--workspace-configs=}"; shift ;;
    --allowed-writes)       allowed_writes_path="${2:-}"; shift 2 ;;
    --allowed-writes=*)     allowed_writes_path="${1#--allowed-writes=}"; shift ;;
    -h|--help)
      sed -n '3,18p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$plan_path" ]] || nyann::die "--plan is required"
[[ -f "$plan_path" ]] || nyann::die "plan not found: $plan_path"
[[ -d "$target_root" ]] || nyann::die "target is not a directory: $target_root"
target_root="$(cd "$target_root" && pwd)"

# --- template context --------------------------------------------------------

primary_language="unknown"
framework="null"
package_manager="null"
is_monorepo=false

if [[ -n "$stack_path" ]]; then
  [[ -f "$stack_path" ]] || nyann::die "stack file not found: $stack_path"
  primary_language="$(jq -r '.primary_language // "unknown"' "$stack_path")"
  framework="$(jq -r '.framework // "null"' "$stack_path")"
  package_manager="$(jq -r '.package_manager // "null"' "$stack_path")"
  is_monorepo="$(jq -r '.is_monorepo // false' "$stack_path")"
fi

[[ -n "$project_name" ]] || project_name="$(basename "$target_root")"

today="$(date +%Y-%m-%d)"

framework_or_na="$framework"
package_manager_or_na="$package_manager"
[[ "$framework_or_na"      == "null" ]] && framework_or_na="(none)"
[[ "$package_manager_or_na" == "null" ]] && package_manager_or_na="(none)"

# Render a template by substituting {{var}} tokens. Also supports
# {{#if var}}...{{/if}} when `var` is one of the known locals — strip the
# whole block if the variable is "null" / empty, else unwrap it.
#
# All substitution values flow to perl through environment variables
# (perl reads them as $ENV{NAME}). The env-var pattern avoids the
# value ever entering a bash-evaluated string, preventing RCE via
# backtick expansion or double-quote string termination.
#
# mktemp + RETURN trap so perl failures do not orphan the temp file.
# Create $tmp next to $dst so the final `mv` is atomic (both on the
# same filesystem).
render_template() {
  local src="$1"; local dst="$2"
  local tmp rc=0
  tmp="$(mktemp "$(dirname "$dst")/.nyann-tmpl.XXXXXX" 2>/dev/null \
       || mktemp -t nyann-tmpl.XXXXXX)"

  # Single cleanup path: if any step in the grouped block fails under
  # set -e, the || fires and removes the temp file. On success, `mv`
  # has already moved the temp to $dst so the rm is a no-op — but we
  # only run it on failure, so it's strictly defensive.
  {
    cp "$src" "$tmp"

    # Conditional blocks per known variable. Add new vars here as
    # templates start using them. Opener/closer literals do not carry
    # user input, so the NYANN_VAR indirection covers the only field
    # that does.
    local var val
    for var in framework package_manager; do
      case "$var" in
        framework)       val="$framework" ;;
        package_manager) val="$package_manager" ;;
      esac
      if [[ "$val" == "null" || -z "$val" ]]; then
        NYANN_VAR="$var" perl -0777 -i -pe '
          my $v = $ENV{NYANN_VAR};
          s/\{\{#if \Q$v\E\}\}.*?\{\{\/if\}\}//gs;
        ' "$tmp"
      else
        NYANN_VAR="$var" perl -0777 -i -pe '
          my $v = $ENV{NYANN_VAR};
          s/\{\{#if \Q$v\E\}\}//g;
        ' "$tmp"
      fi
    done
    # Drop every remaining {{/if}} paired with an opener we kept.
    perl -0777 -i -pe 's/\{\{\/if\}\}//g' "$tmp"

    # Straight substitutions — values enter perl as env vars only.
    # Previously these were `$(esc "$var")` interpolated into a
    # double-quoted bash string, which left backticks / double-quotes
    # in user-controlled values exploitable.
    NYANN_PROJECT_NAME="$project_name" \
    NYANN_PRIMARY_LANGUAGE="$primary_language" \
    NYANN_FRAMEWORK="$framework" \
    NYANN_FRAMEWORK_OR_NA="$framework_or_na" \
    NYANN_PACKAGE_MANAGER="$package_manager" \
    NYANN_PACKAGE_MANAGER_OR_NA="$package_manager_or_na" \
    NYANN_IS_MONOREPO="$is_monorepo" \
    NYANN_DATE="$today" \
    perl -i -pe '
      s/\{\{project_name\}\}/$ENV{NYANN_PROJECT_NAME}/g;
      s/\{\{primary_language\}\}/$ENV{NYANN_PRIMARY_LANGUAGE}/g;
      s/\{\{framework\}\}/$ENV{NYANN_FRAMEWORK}/g;
      s/\{\{framework_or_na\}\}/$ENV{NYANN_FRAMEWORK_OR_NA}/g;
      s/\{\{package_manager\}\}/$ENV{NYANN_PACKAGE_MANAGER}/g;
      s/\{\{package_manager_or_na\}\}/$ENV{NYANN_PACKAGE_MANAGER_OR_NA}/g;
      s/\{\{is_monorepo\}\}/$ENV{NYANN_IS_MONOREPO}/g;
      s/\{\{date\}\}/$ENV{NYANN_DATE}/g;
    ' "$tmp"

    mv "$tmp" "$dst"
  } || rc=$?

  if (( rc != 0 )); then
    rm -f "$tmp"
    return "$rc"
  fi
}

# Create a file only when absent. Returns 0 whether we wrote or skipped.
write_if_missing() {
  local src="$1"; local dst="$2"; local kind="${3:-file}"
  if [[ -e "$dst" ]]; then
    nyann::log "skip (exists): $dst"
    return 0
  fi
  # Refuse to write through a symlink at $dst. `-e` already catches a
  # symlink-to-existing-target, but a dangling symlink evaluates false
  # under `-e` while `cp`/`perl -i` would still follow it.
  if [[ -L "$dst" ]]; then
    nyann::die "refusing to write $kind via symlink: $dst"
  fi
  mkdir -p "$(dirname "$dst")"
  render_template "$src" "$dst"
  nyann::log "wrote $kind: $dst"
}

# --- iterate plan targets ----------------------------------------------------

plan_json="$(cat "$plan_path")"

# Archetype expansion happens upstream in bin/route-docs.sh (the
# planner). scaffold-docs.sh is a pure materializer: it iterates the
# .targets[] it receives. This separation keeps the
# preview-before-mutate contract intact — what's in the SHA-bound
# ActionPlan is what gets written. A thin DocumentationPlan with
# use_archetype_scaffolds:true but empty targets[] produces zero
# scaffolds here; callers must run route-docs first to get a fully
# expanded plan.
#
# If the plan still carries archetype + use_archetype_scaffolds
# fields (route-docs propagates them for downstream visibility),
# they're informational only — scaffold-docs ignores them.

target_type() { jq -r --arg k "$1" '(.targets // {})[$k].type // ""' <<<"$plan_json"; }
target_path() { jq -r --arg k "$1" '(.targets // {})[$k].path // ""' <<<"$plan_json"; }

# safe_target_path <key>
# Resolves .targets[<key>].path against $target_root and verifies the
# result stays inside the repo. A DocumentationPlan authored by hand
# (or generated by a future buggy skill) could carry `"path": "../..
# /tmp/pwn"` — without this guard, mkdir/write_if_missing would happily
# escape the repo. Empty paths return empty (callers already gate on
# that via target_type checks).
safe_target_path() {
  local key="$1" rel
  rel="$(target_path "$key")"
  [[ -z "$rel" ]] && { printf ''; return 0; }
  if [[ "$rel" == /* || "$rel" == *".."* ]]; then
    nyann::die "documentation plan target '$key' has unsafe path '$rel' (absolute or contains '..')"
  fi
  if [[ -L "$target_root/$rel" ]]; then
    nyann::die "refusing to write $key via symlink: $target_root/$rel"
  fi
  nyann::assert_path_under_target "$target_root" "$target_root/$rel" \
    "documentation plan target '$key'"
}

# docs/ README always lands when any docs/* target is local. v1.6.0
# adds api_reference, runbook, deployment, glossary to the trigger set.
any_docs=false
for key in architecture prd adrs research api_reference runbook deployment glossary; do
  if [[ "$(target_type "$key")" == "local" ]]; then
    any_docs=true
    break
  fi
done

if $any_docs; then
  # Derive the doc-index location from the architecture target's
  # path when it's local (the architecture doc is the most universal
  # cross-archetype anchor — its parent dir is the right home for
  # the doc README). Falls back to the conventional `docs/README.md`
  # when architecture is non-local or unset, preserving pre-v1.6.x
  # behaviour.
  readme_dir="docs"
  if [[ "$(target_type architecture)" == "local" ]]; then
    arch_path="$(target_path architecture)"
    if [[ -n "$arch_path" ]]; then
      arch_parent="$(dirname "$arch_path")"
      [[ -n "$arch_parent" && "$arch_parent" != "." ]] && readme_dir="$arch_parent"
    fi
  fi
  write_if_missing "$template_root/docs/README.tmpl" "$target_root/$readme_dir/README.md" "doc index"
fi

# architecture
if [[ "$(target_type architecture)" == "local" ]]; then
  write_if_missing "$template_root/docs/architecture.tmpl" \
    "$(safe_target_path architecture)" "architecture doc"
fi

# prd
if [[ "$(target_type prd)" == "local" ]]; then
  write_if_missing "$template_root/docs/prd.tmpl" \
    "$(safe_target_path prd)" "PRD"
fi

# adrs — directory with README + template + ADR-000
if [[ "$(target_type adrs)" == "local" ]]; then
  adr_dir="$(safe_target_path adrs)"
  mkdir -p "$adr_dir"
  write_if_missing "$template_root/docs/decisions/README.tmpl" \
    "$adr_dir/README.md" "ADR index"
  write_if_missing  "$template_root/docs/decisions/ADR-template.md" \
    "$adr_dir/ADR-template.md" "ADR template"
  write_if_missing  "$template_root/docs/decisions/ADR-000-record-architecture-decisions.md" \
    "$adr_dir/ADR-000-record-architecture-decisions.md" "ADR-000"
fi

# research — directory with README + .gitkeep so empty dir commits
if [[ "$(target_type research)" == "local" ]]; then
  rs_dir="$(safe_target_path research)"
  mkdir -p "$rs_dir"
  write_if_missing "$template_root/docs/research-README.tmpl" \
    "$rs_dir/README.md" "research index"
  [[ -e "$rs_dir/.gitkeep" ]] || : > "$rs_dir/.gitkeep"
fi

# v1.6.0 archetype-aware doc types ------------------------------------------

# api-reference — API service / library endpoint catalog
if [[ "$(target_type api_reference)" == "local" ]]; then
  write_if_missing "$template_root/docs/api-reference.tmpl" \
    "$(safe_target_path api_reference)" "API reference"
fi

# runbook — operational playbook (api-service / cli / web-app / mobile-app)
if [[ "$(target_type runbook)" == "local" ]]; then
  write_if_missing "$template_root/docs/runbook.tmpl" \
    "$(safe_target_path runbook)" "runbook"
fi

# deployment — how the system ships
if [[ "$(target_type deployment)" == "local" ]]; then
  write_if_missing "$template_root/docs/deployment.tmpl" \
    "$(safe_target_path deployment)" "deployment doc"
fi

# glossary — domain-term reference (sleeper hit for AI second-brain)
if [[ "$(target_type glossary)" == "local" ]]; then
  write_if_missing "$template_root/docs/glossary.tmpl" \
    "$(safe_target_path glossary)" "glossary"
  # v1.7.0: when the profile opts in via documentation.glossary.auto_populate,
  # seed (or refresh) the auto block with detected exported types.
  if $auto_glossary; then
    "${_script_dir}/scaffold-glossary.sh" \
      --target "$target_root" \
      --max-terms "$glossary_max_terms" \
      --languages "$glossary_languages" \
      || nyann::warn "scaffold-glossary failed; the template seed remains in place"
  fi
fi

# memory — always local by invariant
if [[ "$(target_type memory)" == "local" ]]; then
  mem_dir="$(safe_target_path memory)"
  mkdir -p "$mem_dir"
  write_if_missing "$template_root/memory/README.tmpl" \
    "$mem_dir/README.md" "memory index"
  [[ -e "$mem_dir/.gitkeep" ]] || : > "$mem_dir/.gitkeep"
fi

# Surface a note for any MCP targets we're skipping. The `.targets //
# {}` guard tolerates a hand-crafted plan that omits targets or sets
# it to null — without it, jq exits non-zero and the process
# substitution silently swallows the failure (set -e doesn't propagate
# from process subs), leaving the loop to no-op without a warning.
while IFS= read -r key; do
  t="$(target_type "$key")"
  case "$t" in local|"") ;; *) nyann::warn "skipped non-local target $key (type=$t); MCP routing planned for a future release" ;; esac
done < <(jq -r '(.targets // {}) | keys[]' <<<"$plan_json")

# --- per-workspace docs (v1.9.0) ---------------------------------------------
# When workspace configs are provided, scaffold workspace-local docs/ directories
# for workspaces whose assigned profile declares documentation.scaffold_types.

if [[ -n "${workspace_configs_path:-}" && -f "${workspace_configs_path:-}" ]]; then
  ws_count=$(jq 'length' "$workspace_configs_path")
  for (( wi=0; wi<ws_count; wi++ )); do
    # Subshell isolates per-workspace stack context (primary_language,
    # framework, package_manager, *_or_na, project_name) from the root
    # render context. Without this, every workspace doc would inherit
    # the root repo's stack metadata — a Python workspace under a TS
    # root would get TS-flavoured architecture/PRD copy. Codex
    # adversarial review #3.
    (
      ws_entry=$(jq -c ".[$wi]" "$workspace_configs_path")
      ws_path=$(jq -r '.path' <<<"$ws_entry")
      ws_doc=$(jq -c '.documentation // null' <<<"$ws_entry")
      [[ "$ws_doc" == "null" ]] && exit 0

      ws_scaffold_types=$(jq -r '.scaffold_types // [] | .[]' <<<"$ws_doc")
      [[ -z "$ws_scaffold_types" ]] && exit 0

      # Path traversal guard — same check as the main scaffold path
      if [[ -z "$ws_path" || "$ws_path" == /* || "$ws_path" == *".."* ]]; then
        nyann::warn "skipping workspace with unsafe path: $ws_path"
        exit 0
      fi
      ws_doc_dir="$target_root/$ws_path/docs"
      if ! nyann::assert_path_under_target "$target_root" "$ws_doc_dir" "workspace docs dir" 2>/dev/null; then
        nyann::warn "skipping workspace path escaping target: $ws_path"
        exit 0
      fi
      ws_name=$(basename "$ws_path")

      # --- per-workspace template context overrides --------------------------
      # Shadow the root-level globals so render_template uses the workspace's
      # stack metadata. Variables read by render_template: primary_language,
      # framework, package_manager, framework_or_na, package_manager_or_na,
      # is_monorepo (kept as root), project_name (now the workspace name).
      primary_language=$(jq -r '.primary_language // "unknown"' <<<"$ws_entry")
      _ws_fw=$(jq -r '.framework // empty' <<<"$ws_entry")
      framework="${_ws_fw:-null}"
      _ws_pm=$(jq -r '.package_manager // empty' <<<"$ws_entry")
      package_manager="${_ws_pm:-null}"
      framework_or_na="$framework"
      package_manager_or_na="$package_manager"
      [[ "$framework_or_na"      == "null" ]] && framework_or_na="(none)"
      [[ "$package_manager_or_na" == "null" ]] && package_manager_or_na="(none)"
      project_name="$ws_name"
      # is_monorepo intentionally stays true (inherited from root) — workspace
      # docs render in the context of a monorepo.

      nyann::log "scaffolding workspace docs: $ws_path (language=$primary_language)"

      # Runtime preview-before-mutate gate. When --allowed-writes is set,
      # only write workspace doc paths that the operator explicitly saw
      # in the ActionPlan preview. Defends against planner/executor drift
      # — e.g., if plan-bootstrap.sh and resolve-workspace-configs.sh ever
      # disagree on which scaffolds should fire, this catches the gap at
      # write time. When --allowed-writes is unset, the function allows
      # every write (back-compat for direct callers).
      _ws_allowed_check() {
        local _rel="$1"
        [[ -z "$allowed_writes_path" ]] && return 0
        if [[ ! -f "$allowed_writes_path" ]]; then
          return 0  # absent file → no gating, same back-compat
        fi
        if grep -Fxq "$_rel" "$allowed_writes_path"; then
          return 0
        fi
        nyann::warn "skipping workspace doc: $_rel not in ActionPlan.writes[] (plan-builder must enumerate it for preview-before-mutate)"
        return 1
      }

      # Symlink-mediated escape guard. write_if_missing refuses leaf
      # symlinks at the destination, but mkdir -p happily follows
      # symlinks at INTERMEDIATE path components. A repo with a
      # pre-placed symlink at packages/<ws>/docs/decisions (or any
      # ancestor) pointing to /etc/ would otherwise redirect doc
      # scaffolding outside the target tree on `mkdir -p
      # "$ws_doc_dir/decisions"` + the subsequent README.md write.
      # Verify every existing component from target_root down to the
      # destination dir is a real directory, then mkdir, then re-verify
      # the resolved canonical path stays under target.
      _ws_safe_mkdir() {
        local _rel_dir="$1"            # e.g. packages/api/docs/decisions
        local _full="$target_root/$_rel_dir"
        local _walk="$target_root" _seg
        local _ifs_save="$IFS"
        IFS='/'
        # shellcheck disable=SC2086
        set -- $_rel_dir
        IFS="$_ifs_save"
        for _seg in "$@"; do
          [[ -z "$_seg" ]] && continue
          _walk="$_walk/$_seg"
          if [[ -L "$_walk" ]]; then
            nyann::warn "skipping workspace doc: intermediate component is a symlink: $_walk"
            return 1
          fi
        done
        mkdir -p "$_full" || {
          nyann::warn "skipping workspace doc: mkdir failed for $_rel_dir"
          return 1
        }
        if ! nyann::path_under_target "$target_root" "$_full" >/dev/null 2>&1; then
          nyann::warn "skipping workspace doc: resolved path escapes target: $_rel_dir"
          return 1
        fi
        return 0
      }

      while IFS= read -r stype; do
        [[ -z "$stype" ]] && continue
        case "$stype" in
          architecture)
            if _ws_allowed_check "${ws_path}/docs/architecture.md" && \
               _ws_safe_mkdir "${ws_path}/docs"; then
              write_if_missing "$template_root/docs/architecture.tmpl" \
                "$ws_doc_dir/architecture.md" "workspace $ws_name architecture"
            fi
            ;;
          prd)
            if _ws_allowed_check "${ws_path}/docs/prd.md" && \
               _ws_safe_mkdir "${ws_path}/docs"; then
              write_if_missing "$template_root/docs/prd.tmpl" \
                "$ws_doc_dir/prd.md" "workspace $ws_name PRD"
            fi
            ;;
          adrs)
            if _ws_allowed_check "${ws_path}/docs/decisions/README.md" && \
               _ws_safe_mkdir "${ws_path}/docs/decisions"; then
              write_if_missing "$template_root/docs/decisions/README.tmpl" \
                "$ws_doc_dir/decisions/README.md" "workspace $ws_name ADR index"
            fi
            if _ws_allowed_check "${ws_path}/docs/decisions/ADR-template.md" && \
               _ws_safe_mkdir "${ws_path}/docs/decisions"; then
              write_if_missing "$template_root/docs/decisions/ADR-template.md" \
                "$ws_doc_dir/decisions/ADR-template.md" "workspace $ws_name ADR template"
            fi
            ;;
          research)
            if _ws_allowed_check "${ws_path}/docs/research/README.md" && \
               _ws_safe_mkdir "${ws_path}/docs/research"; then
              write_if_missing "$template_root/docs/research-README.tmpl" \
                "$ws_doc_dir/research/README.md" "workspace $ws_name research index"
              [[ -e "$ws_doc_dir/research/.gitkeep" ]] || : > "$ws_doc_dir/research/.gitkeep"
            fi
            ;;
          api_reference)
            if _ws_allowed_check "${ws_path}/docs/api-reference.md" && \
               _ws_safe_mkdir "${ws_path}/docs"; then
              write_if_missing "$template_root/docs/api-reference.tmpl" \
                "$ws_doc_dir/api-reference.md" "workspace $ws_name API reference"
            fi
            ;;
          runbook)
            if _ws_allowed_check "${ws_path}/docs/runbook.md" && \
               _ws_safe_mkdir "${ws_path}/docs"; then
              write_if_missing "$template_root/docs/runbook.tmpl" \
                "$ws_doc_dir/runbook.md" "workspace $ws_name runbook"
            fi
            ;;
          deployment)
            if _ws_allowed_check "${ws_path}/docs/deployment.md" && \
               _ws_safe_mkdir "${ws_path}/docs"; then
              write_if_missing "$template_root/docs/deployment.tmpl" \
                "$ws_doc_dir/deployment.md" "workspace $ws_name deployment doc"
            fi
            ;;
          glossary)
            if _ws_allowed_check "${ws_path}/docs/glossary.md" && \
               _ws_safe_mkdir "${ws_path}/docs"; then
              write_if_missing "$template_root/docs/glossary.tmpl" \
                "$ws_doc_dir/glossary.md" "workspace $ws_name glossary"
            fi
            ;;
        esac
      done <<<"$ws_scaffold_types"
    )
  done
fi
