#!/usr/bin/env bash
# boot-record.sh — pre-mutation snapshot helpers for bootstrap.sh and
# retrofit.sh. Source me; call nyann::br_init <target> <source> <profile>
# <plan> at the top, then nyann::br_snapshot before each file mutation,
# nyann::br_action_* for git-level actions, and nyann::br_finalize at
# the end (or via EXIT trap so partial runs still produce a record).
#
# The record lands at:
#   <target>/memory/.nyann/bootstraps/<ISO-ts>/manifest.json
#   <target>/memory/.nyann/bootstraps/<ISO-ts>/pre-state/NNNN.bin
#
# Format is locked by schemas/boot-record.schema.json. Consumed by
# bin/undo-bootstrap.sh.
#
# Idempotent: nyann::br_snapshot on the same path twice no-ops the second
# call (the first snapshot is the authoritative pre-state). Dry-run mode
# (caller sets _BR_DRY_RUN=true before init) writes nothing.

# State (set by nyann::br_init; readable for caller use after):
#   _BR_ACTIVE         — "true" once init succeeded, "false" otherwise
#   _BR_DIR            — record directory (memory/.nyann/bootstraps/<ts>)
#   _BR_PRE_STATE      — $_BR_DIR/pre-state
#   _BR_ACTIONS_FILE   — actions.jsonl (one JSON object per line)
#   _BR_TRACKED_FILE   — tracked.tsv: path<TAB>blob<TAB>existed<TAB>sha256
#   _BR_HEADER_FILE    — header.json: top-level fields written at init
#   _BR_BLOB_COUNTER   — incremented on each snapshot

_BR_ACTIVE="${_BR_ACTIVE:-false}"
_BR_DRY_RUN="${_BR_DRY_RUN:-false}"

# nyann::br_init <target> <source> <profile_path> <plan_path>
nyann::br_init() {
  local target="${1:?target required}"
  local source="${2:?source required}"
  local profile_path="${3:?profile required}"
  local plan_path="${4:?plan required}"

  case "$source" in
    bootstrap|retrofit) ;;
    *) nyann::die "br_init: source must be bootstrap|retrofit (got: $source)" ;;
  esac

  if [[ "$_BR_DRY_RUN" == "true" ]]; then
    _BR_ACTIVE="false"
    return 0
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  local root="$target/memory/.nyann/bootstraps"
  local dir="$root/$ts"
  # Disambiguate clock collisions (rare in practice — protects test runs).
  local n=1
  while [[ -e "$dir" ]]; do
    dir="$root/$ts-$n"
    n=$((n + 1))
  done
  mkdir -p "$dir/pre-state"

  _BR_DIR="$dir"
  _BR_PRE_STATE="$dir/pre-state"
  _BR_ACTIONS_FILE="$dir/.actions.jsonl"
  _BR_TRACKED_FILE="$dir/.tracked.tsv"
  _BR_HEADER_FILE="$dir/.header.json"
  _BR_BLOB_COUNTER=0
  : > "$_BR_ACTIONS_FILE"
  : > "$_BR_TRACKED_FILE"

  local profile_sha plan_sha
  # Both shas are over the canonicalised (jq -Sc) JSON, matching the
  # schema's documented contract — we must hash the same bytes a
  # consumer would compute, not the raw file (which would be sensitive
  # to whitespace and key order).
  profile_sha=$(_br_sha256_file_canon "$profile_path") || nyann::die "br_init: cannot hash profile $profile_path"
  plan_sha=$(_br_sha256_file_canon "$plan_path") || nyann::die "br_init: cannot hash plan $plan_path"

  jq -n \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg target "$target" \
    --arg source "$source" \
    --arg profile_name "$(jq -r '.name // "unknown"' "$profile_path")" \
    --arg profile_sha256 "$profile_sha" \
    --arg plan_sha256 "$plan_sha" \
    '{
      schema_version: 1,
      created_at: $created_at,
      target: $target,
      source: $source,
      profile_name: $profile_name,
      profile_sha256: $profile_sha256,
      plan_sha256: $plan_sha256
    }' > "$_BR_HEADER_FILE"

  _BR_ACTIVE="true"
  nyann::log "boot-record: $dir"
}

# nyann::br_snapshot <category> <repo-relative-path> [<plan-action>]
# Snapshots the file's pre-state (bytes copied to pre-state/, sha256 stored).
# Tracks the path so br_finalize_writes can diff against current state.
# Optional <plan-action> overrides finalize_writes' inferred action
# enum — pass the plan-declared `action` (e.g., "merge") so the BootRecord
# action faithfully reflects what the plan asked for, rather than
# collapsing every existed:true:true case to "overwrite".
nyann::br_snapshot() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  local category="${1:?category required}"
  local path="${2:?path required}"
  local plan_action="${3-}"

  case "$category" in
    docs|hooks|branching|gitignore|editorconfig|github) ;;
    *) nyann::warn "br_snapshot: unknown category '$category' for $path"; return 0 ;;
  esac

  # Idempotent: skip if already tracked. \037 is the field separator
  # (see br_snapshot's printf below for rationale).
  if [[ -s "$_BR_TRACKED_FILE" ]] && awk -F'\037' -v p="$path" '$1==p{f=1; exit} END{exit !f}' "$_BR_TRACKED_FILE"; then
    return 0
  fi

  local target full
  target=$(jq -r '.target' "$_BR_HEADER_FILE")

  # String-level path-traversal guard. Reject paths with absolute
  # prefix or `..` segments — a malicious plan.json with
  # `"path": "../../.ssh/id_rsa"` would otherwise trigger a cp outside
  # the repo into pre-state/ (which is committed by default).
  if [[ "$path" == /* || "$path" == *".."* ]]; then
    nyann::warn "br_snapshot: refusing path that escapes target: $path"
    return 0
  fi
  # Reject control characters that would corrupt tracked.tsv.
  # `\n` is the record delimiter and `\037` is the field delimiter;
  # paths containing either would split rows mid-stream and produce
  # schema-invalid manifest entries. POSIX allows newlines in
  # filenames, so this is a real (if rare) refusal — flagging it
  # explicitly is better than emitting garbage.
  case "$path" in
    *$'\n'*|*$'\037'*)
      nyann::warn "br_snapshot: refusing path with control characters (\\n or \\037): $(printf '%q' "$path")"
      return 0
      ;;
  esac
  full="$target/$path"

  local existed="false" blob="" sha=""
  # Refuse to snapshot through a symlink — restoring it later is ambiguous.
  # Check this BEFORE path_under_target so legitimate symlinks at safe
  # paths get the irreversible-symlink-action treatment instead of being
  # rejected outright. A symlink at a string-clean path is recorded
  # safely; a `..`-bearing path was already rejected above.
  if [[ -L "$full" ]]; then
    # Field separator is US (\037) — tab collapses with bash IFS whitespace
    # default, eating empty middle fields. US has no such collision.
    # Pack the original category into the sha column so finalize_writes
    # can restore it on emit (the literal "symlink" marker still occupies
    # the category column to keep the symlink branch easy to recognise).
    printf '%s\037\037%s\037%s\037symlink\037%s\n' "$path" "false" "$category" "$plan_action" >> "$_BR_TRACKED_FILE"
    return 0
  fi

  # Symlink-traversal guard for non-leaf cases: a string-clean path like
  # `dir/file` where `dir` is itself a pre-existing symlink to /etc would
  # cause `cp` to read /etc/file. Resolve the path with symlinks
  # collapsed, refuse if it lands outside the target.
  if ! nyann::path_under_target "$target" "$full" >/dev/null 2>&1; then
    nyann::warn "br_snapshot: path resolves outside target via symlink, refusing: $path"
    return 0
  fi

  if [[ -f "$full" ]]; then
    _BR_BLOB_COUNTER=$((_BR_BLOB_COUNTER + 1))
    blob="$(printf '%04d.bin' "$_BR_BLOB_COUNTER")"
    # Catch cp failures (permission denied, file vanished mid-snapshot)
    # so a single unreadable file doesn't abort the entire bootstrap
    # via errexit. Mark the row as a copy-failure (`cpfail` token in the
    # category column) so finalize_writes emits an irreversible action.
    if ! cp -- "$full" "$_BR_PRE_STATE/$blob" 2>/dev/null; then
      nyann::warn "br_snapshot: cp failed for $path — recording as irreversible"
      _BR_BLOB_COUNTER=$((_BR_BLOB_COUNTER - 1))
      blob=""
      printf '%s\037\037%s\037%s\037cpfail\037%s\n' "$path" "true" "$category" "$plan_action" >> "$_BR_TRACKED_FILE"
      return 0
    fi
    sha=$(_br_sha256_file "$_BR_PRE_STATE/$blob")
    existed="true"
  fi

  printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$path" "$blob" "$existed" "$sha" "$category" "$plan_action" >> "$_BR_TRACKED_FILE"
}

# nyann::br_snapshot_dir <category> <repo-relative-dir>
# Recursively snapshot every file under <dir>. Skips on missing dir.
nyann::br_snapshot_dir() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  local category="${1:?category required}"
  local rel="${2:?path required}"
  local target
  target=$(jq -r '.target' "$_BR_HEADER_FILE")
  local full="$target/$rel"
  [[ -d "$full" ]] || return 0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local relfile="${f#"$target"/}"
    nyann::br_snapshot "$category" "$relfile"
  done < <(find "$full" -type f 2>/dev/null)
}

# nyann::br_register_post_dir <category> <repo-relative-dir>
# Mark a directory whose contents should be diffed against tracked.tsv
# at finalize time. Any file present there post-mutation that wasn't
# pre-snapshotted gets a `create` write action emitted in the manifest.
# Closes the gap where install-hooks materialises .git/hooks/pre-commit
# (and similar) on a fresh repo where the file didn't exist pre-bootstrap.
_BR_POST_DIRS_FILE=""
nyann::br_register_post_dir() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  local category="${1:?category required}"
  local rel="${2:?path required}"
  : "${_BR_POST_DIRS_FILE:=$_BR_DIR/.post-dirs.tsv}"
  printf '%s\037%s\n' "$category" "$rel" >> "$_BR_POST_DIRS_FILE"
}

# nyann::br_action_git_init
nyann::br_action_git_init() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  jq -nc '{kind:"git-init", category:"branching"}' >> "$_BR_ACTIONS_FILE"
}

# nyann::br_action_seed_commit <sha>
nyann::br_action_seed_commit() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  jq -nc --arg sha "${1:?sha required}" '{kind:"seed-commit", category:"branching", sha:$sha}' >> "$_BR_ACTIONS_FILE"
}

# nyann::br_action_branch <name> <base_sha>
nyann::br_action_branch() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  jq -nc \
    --arg name "${1:?name required}" \
    --arg base_sha "${2:?base_sha required}" \
    '{kind:"branch", category:"branching", name:$name, base_sha:$base_sha}' \
    >> "$_BR_ACTIONS_FILE"
}

# nyann::br_action_default_rename <from> <to>
nyann::br_action_default_rename() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  jq -nc \
    --arg from "${1:?from required}" \
    --arg to "${2:?to required}" \
    '{kind:"default-branch-rename", category:"branching", from:$from, to:$to}' \
    >> "$_BR_ACTIONS_FILE"
}

# nyann::br_finalize_writes
# Walks the tracked file, compares each tracked path's current bytes
# against its pre-state snapshot, and appends a write action for each
# path whose state changed (created, deleted, or modified). After the
# tracked sweep, scans every directory registered via
# nyann::br_register_post_dir and emits create actions for any file
# present there post-mutation that wasn't pre-snapshotted (e.g.,
# .git/hooks/pre-commit on a fresh-bootstrap repo).
nyann::br_finalize_writes() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  local target
  target=$(jq -r '.target' "$_BR_HEADER_FILE")

  # Scan post-dirs first, registering any new files into tracked.tsv
  # with pre_existed=false so the main loop emits create actions.
  if [[ -n "${_BR_POST_DIRS_FILE:-}" && -f "$_BR_POST_DIRS_FILE" ]]; then
    local pd_cat pd_rel
    while IFS=$'\037' read -r pd_cat pd_rel; do
      [[ -z "$pd_cat" || -z "$pd_rel" ]] && continue
      local pd_full="$target/$pd_rel"
      [[ -d "$pd_full" ]] || continue
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local relfile="${f#"$target"/}"
        # Skip if already tracked (a pre-existing file the snapshot caught).
        if [[ -s "$_BR_TRACKED_FILE" ]] && \
           awk -F'\037' -v p="$relfile" '$1==p{f=1; exit} END{exit !f}' "$_BR_TRACKED_FILE"; then
          continue
        fi
        # Register as a create-action: pre-state was empty.
        printf '%s\037\037%s\037\037%s\037\n' "$relfile" "false" "$pd_cat" >> "$_BR_TRACKED_FILE"
      done < <(find "$pd_full" -type f 2>/dev/null)
    done < "$_BR_POST_DIRS_FILE"
  fi

  [[ -s "$_BR_TRACKED_FILE" ]] || return 0

  local path blob existed sha category
  local path blob existed sha category plan_action
  while IFS=$'\037' read -r path blob existed sha category plan_action; do
    [[ -z "$path" ]] && continue
    plan_action="${plan_action-}"
    # Symlink-marked rows: emit an irreversible write action. The
    # original category is packed into $sha (see br_snapshot's symlink
    # branch); fall back to "hooks" only if it's missing, so legacy
    # rows from older runs still emit a valid action.
    if [[ "$category" == "symlink" ]]; then
      local orig_cat="${sha:-hooks}"
      jq -nc \
        --arg path "$path" \
        --arg cat "$orig_cat" \
        '{kind:"write", category:$cat, path:$path, action:"overwrite",
          pre_existed:true, reversible:false,
          irreversible_reason:"path is a symlink — pre-state ambiguous"}' \
        >> "$_BR_ACTIONS_FILE"
      continue
    fi

    # cp-failure rows: snapshot couldn't read the pre-state bytes.
    # Emit an irreversible action so undo refuses cleanly rather than
    # restoring corrupt or empty content.
    if [[ "$category" == "cpfail" ]]; then
      local orig_cat="${sha:-hooks}"
      jq -nc \
        --arg path "$path" \
        --arg cat "$orig_cat" \
        '{kind:"write", category:$cat, path:$path, action:"overwrite",
          pre_existed:true, reversible:false,
          irreversible_reason:"could not snapshot pre-state (permission or vanished file)"}' \
        >> "$_BR_ACTIONS_FILE"
      continue
    fi

    local full="$target/$path"
    local now_exists="false"
    [[ -f "$full" ]] && now_exists="true"

    # Determine action:
    #   pre=false now=true  -> create
    #   pre=true  now=true  -> overwrite (or merge — caller can refine)
    #   pre=true  now=false -> delete
    #   pre=false now=false -> no-op (drop)
    local action=""
    case "$existed:$now_exists" in
      false:false) continue ;;
      false:true)  action="create" ;;
      true:false)  action="delete" ;;
      true:true)
        # Skip if bytes unchanged.
        local now_sha
        now_sha=$(_br_sha256_file "$full")
        [[ "$now_sha" == "$sha" ]] && continue
        action="overwrite"
        ;;
    esac

    # Honour plan-declared action when it's set and the schema accepts
    # it. Without this, every existed:true:true case collapses to
    # "overwrite" even when the operator's plan said "merge", which
    # drifts from the BootRecord schema's contract that this field
    # mirrors ActionPlan.writes[].action.
    case "$plan_action" in
      create|merge|overwrite|delete) action="$plan_action" ;;
    esac

    # Capture post-state sha so undo can distinguish user edits from
    # bootstrap's own output. Empty when the action was 'delete'
    # (file no longer present).
    local post_sha=""
    if [[ "$now_exists" == "true" ]]; then
      post_sha=$(_br_sha256_file "$full" || echo "")
    fi

    if [[ "$existed" == "true" ]]; then
      jq -nc \
        --arg path "$path" \
        --arg action "$action" \
        --arg blob "$blob" \
        --arg sha "$sha" \
        --arg post_sha "$post_sha" \
        --arg category "$category" \
        '{kind:"write", category:$category, path:$path, action:$action,
          pre_existed:true, pre_state_blob:$blob, pre_state_sha256:$sha}
         + (if $post_sha == "" then {} else {post_state_sha256:$post_sha} end)
         + {reversible:true}' \
        >> "$_BR_ACTIONS_FILE"
    else
      jq -nc \
        --arg path "$path" \
        --arg action "$action" \
        --arg post_sha "$post_sha" \
        --arg category "$category" \
        '{kind:"write", category:$category, path:$path, action:$action,
          pre_existed:false}
         + (if $post_sha == "" then {} else {post_state_sha256:$post_sha} end)
         + {reversible:true}' \
        >> "$_BR_ACTIONS_FILE"
    fi
  done < "$_BR_TRACKED_FILE"
}

# nyann::br_finalize
# Composes the BootRecord JSON from the header + actions.jsonl and
# writes it to <_BR_DIR>/manifest.json. Removes the .actions.jsonl /
# .tracked.tsv / .header.json scratch files. Echoes the manifest path.
nyann::br_finalize() {
  [[ "$_BR_ACTIVE" == "true" ]] || return 0
  # Idempotency guard: the orchestrator runs finalize inline (in a $(...)
  # subshell) so it can capture the manifest path; the subshell's mutation
  # of _BR_ACTIVE doesn't leak to the parent, so the EXIT-trap fallback
  # would re-enter finalize and clobber the manifest. Bail when the
  # header scratch file is gone — that's the post-finalize signal.
  [[ -f "${_BR_HEADER_FILE:-}" ]] || return 0
  nyann::br_finalize_writes
  local manifest="$_BR_DIR/manifest.json"
  local actions_json="[]"
  if [[ -s "$_BR_ACTIONS_FILE" ]]; then
    actions_json=$(jq -s '.' "$_BR_ACTIONS_FILE")
  fi
  # Atomic write: write to a tempfile then mv into place so a concurrent
  # reader never observes a half-written manifest. mv on the same
  # filesystem is atomic on POSIX. If jq fails, the tempfile stays out
  # of the way and the user gets the actual error rather than a
  # silently-truncated manifest.
  local manifest_tmp="$_BR_DIR/.manifest.json.tmp"
  if ! jq --argjson actions "$actions_json" '. + {actions: $actions}' \
       "$_BR_HEADER_FILE" > "$manifest_tmp"; then
    rm -f "$manifest_tmp"
    nyann::warn "br_finalize: failed to compose manifest.json (jq error)"
    return 1
  fi
  mv -f "$manifest_tmp" "$manifest"
  rm -f "$_BR_ACTIONS_FILE" "$_BR_TRACKED_FILE" "$_BR_HEADER_FILE" \
        "${_BR_POST_DIRS_FILE:-/dev/null}"
  # Mark inactive so a follow-up trap-based finalize is a no-op
  # (idempotent: explicit call from orchestrator + trap fallback).
  _BR_ACTIVE="false"
  printf '%s\n' "$manifest"
}

# --- internal helpers --------------------------------------------------------

_br_sha256_file() {
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

# Canonicalised SHA-256 (jq -Sc) of a JSON file. Matches bootstrap.sh's
# --plan-sha256 binding.
_br_sha256_file_canon() {
  local f="${1-}"
  [[ -f "$f" ]] || return 1
  local canon
  canon=$(jq -Sc . "$f") || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$canon" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canon" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}
