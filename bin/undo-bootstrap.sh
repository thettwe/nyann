#!/usr/bin/env bash
# undo-bootstrap.sh — reverse a bootstrap or retrofit run captured in a
# BootRecord manifest.
#
# Usage:
#   undo-bootstrap.sh --target <repo>
#                     [--manifest <path>]                  # default: newest
#                     [--scope <csv>]                      # default: all
#                     [--dry-run]
#                     [--yes]
#                     [--force]                            # files modified post-bootstrap
#                     [--allow-rebase]                     # HEAD ahead of seed
#                     [--allow-non-empty-branches]         # branch has new commits
#                     [--keep-record]                      # don't remove the manifest dir on success
#
# Emits an UndoBootstrapResult JSON object on stdout. Logs to stderr.
# Mirrors the preview-then-yes flow of bin/undo.sh (commit undo).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

# --- helpers (must be declared before the action loop) ----------------------

_undo_sha256() {
  local f="${1-}"
  [[ -f "$f" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    return 1
  fi
}

target="$PWD"
manifest=""
scope="all"
dry_run=false
yes=false
force=false
allow_rebase=false
allow_non_empty=false
keep_record=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)                    target="${2:-}"; shift 2 ;;
    --target=*)                  target="${1#--target=}"; shift ;;
    --manifest)                  manifest="${2:-}"; shift 2 ;;
    --manifest=*)                manifest="${1#--manifest=}"; shift ;;
    --scope)                     scope="${2:-all}"; shift 2 ;;
    --scope=*)                   scope="${1#--scope=}"; shift ;;
    --dry-run)                   dry_run=true; shift ;;
    --yes)                       yes=true; shift ;;
    --force)                     force=true; shift ;;
    --allow-rebase)              allow_rebase=true; shift ;;
    --allow-non-empty-branches)  allow_non_empty=true; shift ;;
    --keep-record)               keep_record=true; shift ;;
    -h|--help)                   sed -n '3,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                           nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target must be a directory: $target"
target="$(cd "$target" && pwd)"

# Without --yes the operator hasn't confirmed a real run yet — treat it
# as a dry-run for mutation purposes, but still emit the preview JSON.
# Same idiom as bin/undo.sh.
effective_dry_run=$dry_run
if ! $yes; then
  effective_dry_run=true
fi

emit_refused() {
  jq -n \
    --arg target "$target" \
    --arg manifest "$manifest" \
    --arg reason "$1" \
    '{status:"refused", target:$target, manifest_path:(if $manifest=="" then null else $manifest end | tostring), refused_reason:$reason}'
  exit 1
}

# --- locate manifest --------------------------------------------------------

if [[ -z "$manifest" ]]; then
  records_dir="$target/memory/.nyann/bootstraps"
  [[ -d "$records_dir" ]] || emit_refused "no boot records found under $records_dir — has bootstrap ever run here?"
  # Sort by the manifest's `created_at` field (ISO 8601 lex-sortable).
  # Filesystem mtime via `ls -t` is unstable on equal-mtime ties (two
  # bootstraps in the same second pick whichever directory the find
  # walk surfaces first), so we use the JSON contract instead.
  manifest=$(
    find "$records_dir" -mindepth 2 -maxdepth 2 -name manifest.json -type f 2>/dev/null \
    | while IFS= read -r m; do
        ts=$(jq -r '.created_at // ""' "$m" 2>/dev/null)
        [[ -n "$ts" ]] && printf '%s\t%s\n' "$ts" "$m"
      done \
    | sort -r \
    | head -n1 \
    | cut -f2-
  )
  [[ -n "$manifest" && -f "$manifest" ]] || emit_refused "no manifest.json under $records_dir"
fi

[[ -f "$manifest" ]] || emit_refused "manifest not found: $manifest"
manifest="$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")"

# Schema-shape sanity (cheap structural check; full check-jsonschema is the
# nice-to-have, but we don't want to require uvx for undo).
jq -e '.schema_version == 1 and (.actions|type=="array")' "$manifest" >/dev/null \
  || emit_refused "manifest has unexpected shape (not BootRecord v1): $manifest"

manifest_target=$(jq -r '.target' "$manifest")

# Portability: don't compare absolute paths. The manifest's recorded
# target is the path where bootstrap originally ran; a teammate who
# pulled the bootstrap PR into a different clone path would always
# fail an exact-path check even though they're in the same repo.
# Instead, verify the manifest lives under $target — if you found the
# record file inside this repo, you're in the right place.
canonical_target=$(cd "$target" && pwd -P)
canonical_manifest=$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")
case "$canonical_manifest" in
  "$canonical_target"/*) ;;  # manifest is under target — fine.
  *) emit_refused "manifest is not inside target ($canonical_manifest vs $canonical_target). The record was originally written for $manifest_target." ;;
esac

# Source field — used in the result JSON so the operator knows whether
# they're reversing a bootstrap or retrofit run.
manifest_source=$(jq -r '.source // "bootstrap"' "$manifest")

# --- scope handling ---------------------------------------------------------

valid_scopes=(docs hooks branching gitignore editorconfig github all)
declare -a scope_csv=()
if [[ -z "$scope" || "$scope" == "all" ]]; then
  scope_csv=(docs hooks branching gitignore editorconfig github)
else
  # `read -ra raw` does NOT initialize raw[] when the input is empty —
  # the resulting unbound array would die under set -u in the loop. Use
  # `${arr[@]+...}` expansion to guard against that, and fall back to
  # the full scope when raw is empty after parsing.
  declare -a raw=()
  IFS=',' read -ra raw <<<"$scope"
  for s in ${raw[@]+"${raw[@]}"}; do
    s="${s// /}"
    [[ -z "$s" ]] && continue
    found=false
    for v in "${valid_scopes[@]}"; do
      [[ "$s" == "$v" ]] && found=true && break
    done
    $found || emit_refused "unknown scope: $s (want any of: docs hooks branching gitignore editorconfig github all)"
    scope_csv+=("$s")
  done
  if [[ ${#scope_csv[@]} -eq 0 ]]; then
    scope_csv=(docs hooks branching gitignore editorconfig github)
  fi
fi

scope_includes() {
  local needle="$1" s
  for s in ${scope_csv[@]+"${scope_csv[@]}"}; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

# --- pre-flight checks ------------------------------------------------------

# Read all action entries.
actions_json=$(jq -c '.actions' "$manifest")

# Identify seed commit (if any) so we can refuse on stacked work.
seed_sha=$(jq -r '.actions[] | select(.kind=="seed-commit") | .sha' "$manifest" | head -n1)
current_head=""
if git -C "$target" rev-parse HEAD >/dev/null 2>&1; then
  current_head=$(git -C "$target" rev-parse HEAD)
fi

if [[ -n "$seed_sha" && -n "$current_head" && "$current_head" != "$seed_sha" ]]; then
  # Refusal applies uniformly to dry-run/preview AND --yes runs. Gating
  # this on !$effective_dry_run would let the operator approve a preview
  # the confirmed run will reject — breaking preview-before-mutate.
  if ! $allow_rebase; then
    if git -C "$target" merge-base --is-ancestor "$seed_sha" "$current_head" 2>/dev/null; then
      emit_refused "HEAD ($current_head) is ahead of the bootstrap seed commit ($seed_sha) — commits would be lost. Pass --allow-rebase if you really want to drop them."
    fi
  fi
fi

# --- build per-category preview / execution lists ---------------------------

restored_json='[]'
deleted_json='[]'
branches_dropped_json='[]'
seeds_json='[]'
renames_json='[]'
skipped_json='[]'

skip() {
  # $1=kind $2=path-or-name $3=reason
  skipped_json=$(jq -c \
    --arg k "$1" --arg p "$2" --arg r "$3" \
    '. + [{kind:$k, path:$p, reason:$r}]' <<<"$skipped_json")
}

manifest_dir=$(dirname "$manifest")
pre_state="$manifest_dir/pre-state"

# Walk actions in REVERSE order. The manifest records what bootstrap did
# in forward order; reversing matches the natural dependency stack
# (branches were created after the seed commit, so branch-drop happens
# before seed-undo).
total=$(jq -r '. | length' <<<"$actions_json")
i=$((total - 1))
while (( i >= 0 )); do
  a=$(jq -c ".[$i]" <<<"$actions_json")
  kind=$(jq -r '.kind' <<<"$a")
  category=$(jq -r '.category // ""' <<<"$a")
  i=$((i - 1))

  if [[ -n "$category" ]] && ! scope_includes "$category"; then
    continue
  fi

  case "$kind" in
    write)
      path=$(jq -r '.path' <<<"$a")
      reversible=$(jq -r '.reversible' <<<"$a")
      pre_existed=$(jq -r '.pre_existed' <<<"$a")
      blob=$(jq -r '.pre_state_blob // ""' <<<"$a")
      blob_sha=$(jq -r '.pre_state_sha256 // ""' <<<"$a")
      post_sha=$(jq -r '.post_state_sha256 // ""' <<<"$a")

      # Path-traversal guard for hostile manifests. A malicious record
      # committed to a repo could carry `"path": "../../.ssh/id_rsa"`
      # — without this check, the restore cp / rm would hit that path.
      # Defense-in-depth alongside the guard in br_snapshot.
      if [[ "$path" == /* || "$path" == *".."* ]]; then
        skip "write" "$path" "manifest path escapes target — refusing to restore"
        continue
      fi
      full="$target/$path"
      if ! nyann::path_under_target "$target" "$full" >/dev/null 2>&1; then
        skip "write" "$path" "manifest path resolves outside target — refusing to restore"
        continue
      fi

      if [[ "$reversible" != "true" ]]; then
        skip "write" "$path" "$(jq -r '.irreversible_reason // "marked irreversible"' <<<"$a")"
        continue
      fi

      # User-edit detection: when the manifest carries a post_state sha
      # and the current bytes don't match it, somebody edited the file
      # after bootstrap finished. Refuse without --force so the edit
      # isn't silently clobbered.
      if [[ -f "$full" && -n "$post_sha" ]]; then
        current_sha=$(_undo_sha256 "$full")
        if [[ "$current_sha" != "$post_sha" ]]; then
          if [[ "$current_sha" == "$blob_sha" ]]; then
            # Already at pre-state — undo is a no-op for this entry.
            continue
          fi
          if ! $force; then
            skip "write" "$path" "modified after bootstrap (pass --force to overwrite local edits)"
            continue
          fi
        fi
      fi

      if [[ "$pre_existed" == "true" && -n "$blob" ]]; then
        # Restore from blob.
        if ! $effective_dry_run; then
          [[ -f "$pre_state/$blob" ]] || { skip "write" "$path" "pre-state blob missing: $blob"; continue; }
          actual_blob_sha=$(_undo_sha256 "$pre_state/$blob")
          if [[ "$actual_blob_sha" != "$blob_sha" ]]; then
            skip "write" "$path" "pre-state blob sha mismatch (record corruption?): expected $blob_sha got $actual_blob_sha"
            continue
          fi
          mkdir -p "$(dirname "$full")"
          cp -- "$pre_state/$blob" "$full"
        fi
        restored_json=$(jq -c --arg p "$path" --arg c "$category" '. + [{path:$p, category:$c}]' <<<"$restored_json")
        continue
      fi

      # pre_existed=false: bootstrap created it. Reverse = delete.
      if [[ -f "$full" ]]; then
        $effective_dry_run || rm -f -- "$full"
      fi
      deleted_json=$(jq -c --arg p "$path" --arg c "$category" '. + [{path:$p, category:$c}]' <<<"$deleted_json")
      ;;

    branch)
      name=$(jq -r '.name' <<<"$a")
      base=$(jq -r '.base_sha' <<<"$a")
      if ! git -C "$target" rev-parse --verify "refs/heads/$name" >/dev/null 2>&1; then
        skip "branch" "$name" "branch no longer exists"
        continue
      fi
      tip=$(git -C "$target" rev-parse "refs/heads/$name")
      if [[ "$tip" != "$base" ]]; then
        # Same uniform-refusal rationale as the HEAD-ahead check above.
        if ! $allow_non_empty; then
          skip "branch" "$name" "branch has commits past base_sha ($tip vs $base) — pass --allow-non-empty-branches"
          continue
        fi
      fi
      $effective_dry_run || git -C "$target" branch -D -- "$name" >/dev/null
      branches_dropped_json=$(jq -c --arg n "$name" --arg b "$base" '. + [{name:$n, base_sha:$b}]' <<<"$branches_dropped_json")
      ;;

    seed-commit)
      sha=$(jq -r '.sha' <<<"$a")
      if [[ -z "$current_head" ]]; then
        skip "seed-commit" "$sha" "HEAD is unborn"
        continue
      fi
      if [[ "$current_head" != "$sha" ]]; then
        # Unless allow_rebase, the upstream pre-flight already refused
        # the descended-from-seed case. The remaining case is "HEAD is
        # unrelated to seed" — we still skip without --allow-rebase, and
        # apply uniformly so the preview matches the confirmed run.
        if ! $allow_rebase; then
          skip "seed-commit" "$sha" "HEAD has moved past seed; --allow-rebase required"
          continue
        fi
      fi
      # An empty seed commit's parent doesn't exist (it's the first
      # commit), so we can't `git reset --hard HEAD~1`. The cleanest
      # reverse — deleting the branch ref to detach into unborn state —
      # takes the user's working tree along with it, which is too risky
      # to do automatically. Conservative: skip + leave HEAD alone.
      # seed_commits_undone[] only records actual undoes, so it stays
      # empty here; the operator sees the SHA in skipped[] with a manual
      # recovery hint.
      skip "seed-commit" "$sha" "left in place — seed commits are root commits and removing them strands the branch; manually run 'git update-ref -d refs/heads/<branch>' if you really want a fresh start"
      ;;

    default-branch-rename)
      from=$(jq -r '.from' <<<"$a")
      to=$(jq -r '.to' <<<"$a")
      current_branch=$(git -C "$target" branch --show-current 2>/dev/null || echo "")
      if [[ "$current_branch" != "$to" ]]; then
        skip "default-branch-rename" "$to" "current branch is $current_branch, not $to — leaving rename in place"
        continue
      fi
      $effective_dry_run || git -C "$target" branch -m -- "$from"
      renames_json=$(jq -c --arg f "$from" --arg t "$to" '. + [{from:$f, to:$t}]' <<<"$renames_json")
      ;;

    git-init)
      # Hard refusal: removing .git/ destroys all of the user's git state,
      # not just bootstrap's. Operators who know what they're doing can
      # rm -rf .git themselves.
      skip "git-init" ".git" "removing .git/ destroys all git state — do this manually if you really want to"
      ;;

    *)
      skip "$kind" "" "unknown action kind in manifest"
      ;;
  esac
done

# --- emit + cleanup ---------------------------------------------------------

status="undone"
$dry_run && status="preview"
if ! $yes && ! $dry_run; then
  status="preview"
fi

scope_arr=$(printf '%s\n' ${scope_csv[@]+"${scope_csv[@]}"} | jq -R . | jq -sc .)

jq -n \
  --arg status "$status" \
  --arg target "$target" \
  --arg manifest "$manifest" \
  --arg source "$manifest_source" \
  --argjson scope_applied "$scope_arr" \
  --argjson restored "$restored_json" \
  --argjson deleted "$deleted_json" \
  --argjson branches_dropped "$branches_dropped_json" \
  --argjson seed_commits_undone "$seeds_json" \
  --argjson defaults_renamed_back "$renames_json" \
  --argjson skipped "$skipped_json" \
  '{status:$status, target:$target, manifest_path:$manifest, source:$source, scope_applied:$scope_applied,
    restored:$restored, deleted:$deleted, branches_dropped:$branches_dropped,
    seed_commits_undone:$seed_commits_undone, defaults_renamed_back:$defaults_renamed_back,
    skipped:$skipped}'

# Clean up the manifest directory on a real successful run unless asked
# to keep it. We KEEP the record when there are skipped entries the
# operator could re-attempt by adding --force / --allow-non-empty-branches
# (write or branch kinds). Other skip kinds (seed-commit, git-init) are
# intentional permanent deferrals and don't warrant keeping the record.
if [[ "$status" == "undone" ]] && ! $keep_record; then
  reversible_skips=$(jq -r '[.[] | select(.kind=="write" or .kind=="branch")] | length' <<<"$skipped_json")
  if [[ "$reversible_skips" == "0" ]]; then
    rm -rf -- "$manifest_dir"
  fi
fi

exit 0
