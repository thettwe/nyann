#!/usr/bin/env bash
# render-plan.sh — pre-render merge actions in an ActionPlan so
# bin/preview.sh can show a unified diff of what will change.
#
# Usage:
#   render-plan.sh --plan <path> --target <repo> --profile <path> --doc-plan <path>
#                  [--stack <path>] [--workspace-configs <path>]
#                  [--templates-csv <a,b,c>]   # required for .gitignore renders
#                  [--output <path>]           # rendered plan goes here (stdout if omitted)
#
# For each writes[] entry whose action is "merge", invoke the producing
# subsystem in --output mode against a tempdir. The subsystem's
# would-be-merged bytes land at <tempdir>/<basename>; the entry is
# rewritten to carry `preview_blob` (path) and `current_bytes` (size of
# the existing target file, or 0 when absent).
#
# Coverage in v1.7.0:
#   .gitignore  → bin/gitignore-combiner.sh --output
#   CLAUDE.md   → bin/gen-claudemd.sh --output
#
# Other merge actions (Husky hook files, .pre-commit-config.yaml YAML
# merge) are passed through unchanged: no preview_blob, preview.sh
# falls back to size-only display. Adding render-only support to
# install-hooks is a follow-up — it merges via Python and the value of
# diffing it is lower (hook files are short and stable).
#
# The tempdir survives the script. The caller (skill or bootstrap) is
# responsible for cleanup; bootstrap.sh consumes preview_blob via cp
# at execute time and removes the tempdir afterward. preview.sh only
# reads the blobs.
#
# Output: the rewritten ActionPlan JSON on stdout (or --output).
# stderr stays clean for the consumer.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

plan_path=""
target=""
profile_path=""
doc_plan_path=""
stack_path=""
workspace_configs_path=""
templates_csv=""
out_path=""
tmpdir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)             plan_path="${2:-}"; shift 2 ;;
    --plan=*)           plan_path="${1#--plan=}"; shift ;;
    --target)           target="${2:-}"; shift 2 ;;
    --target=*)         target="${1#--target=}"; shift ;;
    --profile)          profile_path="${2:-}"; shift 2 ;;
    --profile=*)        profile_path="${1#--profile=}"; shift ;;
    --doc-plan)         doc_plan_path="${2:-}"; shift 2 ;;
    --doc-plan=*)       doc_plan_path="${1#--doc-plan=}"; shift ;;
    --stack)            stack_path="${2:-}"; shift 2 ;;
    --stack=*)          stack_path="${1#--stack=}"; shift ;;
    --workspace-configs)  workspace_configs_path="${2:-}"; shift 2 ;;
    --workspace-configs=*) workspace_configs_path="${1#--workspace-configs=}"; shift ;;
    --templates-csv)    templates_csv="${2:-}"; shift 2 ;;
    --templates-csv=*)  templates_csv="${1#--templates-csv=}"; shift ;;
    --output)           out_path="${2:-}"; shift 2 ;;
    --output=*)         out_path="${1#--output=}"; shift ;;
    --tmpdir)           tmpdir="${2:-}"; shift 2 ;;
    --tmpdir=*)         tmpdir="${1#--tmpdir=}"; shift ;;
    -h|--help)          sed -n '3,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$plan_path" && -f "$plan_path" ]] || nyann::die "--plan <path> is required"
[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
target="$(cd "$target" && pwd)"

# Caller-supplied tmpdir lets bootstrap.sh share one location for all
# preview blobs and clean up in a single rm -rf at the end. When absent
# we mint our own; the EXIT trap deliberately doesn't remove it because
# preview.sh still has to read the blobs after this script exits.
if [[ -z "$tmpdir" ]]; then
  tmpdir=$(mktemp -d -t nyann-render.XXXXXX)
fi
[[ -d "$tmpdir" ]] || nyann::die "tmpdir does not exist: $tmpdir"

plan_json=$(cat "$plan_path")
jq -e 'has("writes") and has("commands") and has("remote")' <<<"$plan_json" >/dev/null \
  || nyann::die "plan does not match ActionPlan shape"

# Map the two covered paths to a render command. Each writer accepts
# --output and emits the same bytes the in-place mutation would. When
# the entry's action is not "merge" we skip rendering — the diff is
# meaningful only for merges (creates have no current bytes to diff
# against; overwrites are always full-file replacements).

bytes_of() {
  if [[ -f "$1" ]]; then
    wc -c < "$1" | tr -d ' '
  else
    printf '0'
  fi
}

# Produce a rendered plan by walking writes[] and adding preview_blob
# + current_bytes to each merge entry whose path we know how to render.
# Doing this in jq with shell-side sentinels keeps the loop in bash and
# avoids a per-entry jq fork explosion on large plans.
new_writes='[]'
n_rendered=0

while IFS=$'\t' read -r idx path action _bytes; do
  entry=$(jq -c --argjson i "$idx" '.writes[$i]' <<<"$plan_json")

  if [[ "$action" != "merge" ]]; then
    new_writes=$(jq --argjson e "$entry" '. + [$e]' <<<"$new_writes")
    continue
  fi

  blob=""
  case "$path" in
    .gitignore)
      if [[ -n "$templates_csv" ]]; then
        blob="$tmpdir/gitignore.merged"
        # gitignore-combiner refuses --output==--target. The temp blob
        # is by definition different from the target file, so this is
        # safe; the failure mode would be an operator passing the same
        # path explicitly, which the combiner rejects.
        if "${_script_dir}/gitignore-combiner.sh" \
            --target "$target/.gitignore" \
            --output "$blob" \
            --templates "$templates_csv" >/dev/null 2>&1; then
          n_rendered=$((n_rendered + 1))
        else
          # Render failure shouldn't break preview — fall back to
          # size-only display. Tell the operator something went wrong
          # but don't die: the in-place write at execute time will
          # surface the same error if it's real.
          nyann::warn "render failed for $path; preview will fall back to size-only"
          blob=""
        fi
      fi
      ;;
    CLAUDE.md)
      if [[ -n "$profile_path" && -f "$profile_path" \
         && -n "$doc_plan_path" && -f "$doc_plan_path" ]]; then
        blob="$tmpdir/CLAUDE.md.merged"
        local_args=(
          --profile "$profile_path"
          --doc-plan "$doc_plan_path"
          --target "$target"
          --output "$blob"
        )
        [[ -n "$stack_path" ]] && local_args+=(--stack "$stack_path")
        [[ -n "$workspace_configs_path" ]] && local_args+=(--workspace-configs "$workspace_configs_path")
        if "${_script_dir}/gen-claudemd.sh" "${local_args[@]}" >/dev/null 2>&1; then
          n_rendered=$((n_rendered + 1))
        else
          nyann::warn "render failed for $path; preview will fall back to size-only"
          blob=""
        fi
      fi
      ;;
  esac

  if [[ -n "$blob" && -f "$blob" ]]; then
    cur="$(bytes_of "$target/$path")"
    new_writes=$(jq --argjson e "$entry" \
      --arg blob "$blob" \
      --argjson cur "$cur" \
      '. + [$e + {preview_blob: $blob, current_bytes: $cur}]' <<<"$new_writes")
  else
    new_writes=$(jq --argjson e "$entry" '. + [$e]' <<<"$new_writes")
  fi
done < <(
  jq -r '
    .writes
    | to_entries[]
    | [.key, .value.path, .value.action, (.value.bytes // 0)]
    | @tsv
  ' <<<"$plan_json"
)

rendered_plan=$(jq --argjson nw "$new_writes" '.writes = $nw' <<<"$plan_json")

if [[ -n "$out_path" ]]; then
  printf '%s\n' "$rendered_plan" > "$out_path"
  nyann::log "rendered $n_rendered merge preview(s) into $tmpdir; plan written to $out_path"
else
  printf '%s\n' "$rendered_plan"
fi
