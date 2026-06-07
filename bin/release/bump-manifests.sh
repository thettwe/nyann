#!/usr/bin/env bash
# bump-manifests.sh — compute or apply manifest version bumps.
#
# Usage:
#   bump-manifests.sh --mode compute --target <repo> --version <x.y.z>
#                     [--profile <path>] [--dry-run]
#   bump-manifests.sh --mode apply   --target <repo> --version <x.y.z>
#                     --plan-file <path>
#
# Modes:
#   compute — reads profile's release.bump_files[], validates paths,
#             emits a bump plan JSON on stdout. Never writes files.
#   apply   — reads a previously computed plan and applies the bumps.
#             Re-verifies file digests for TOCTOU defense.
#
# Formats (per release.bump_files[].format):
#   json-version-key — jq path (.key) into a JSON manifest (package.json).
#   toml-version-key — single-line `version = "..."` inside [.section] (Cargo.toml).
#   yaml-version-key — top-level `version:` in a Helm Chart.yaml; set .app_version
#                      true to ALSO mirror the app release tag into `appVersion:`.
#   text-version     — whole-file version sentinel (terraform module VERSION file).
#   script           — user command run with $NEW_VERSION (requires --allow-scripts).
#
# Output (JSON on stdout):
#   compute: { "bumped_files": [...], "plan": [...] }
#   apply:   { "applied": N }
#
# Exit codes:
#   0 — success
#   2 — bad arguments or validation failure

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib.sh
source "${_script_dir}/../_lib.sh"

nyann::require_cmd jq

mode=""
target="$PWD"
version=""
profile_path=""
dry_run=false
plan_file=""
allow_scripts=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)        mode="${2:-}"; shift 2 ;;
    --mode=*)      mode="${1#--mode=}"; shift ;;
    --target)      target="${2:-}"; shift 2 ;;
    --target=*)    target="${1#--target=}"; shift ;;
    --version)     version="${2:-}"; shift 2 ;;
    --version=*)   version="${1#--version=}"; shift ;;
    --profile)     profile_path="${2:-}"; shift 2 ;;
    --profile=*)   profile_path="${1#--profile=}"; shift ;;
    --dry-run)     dry_run=true; shift ;;
    --allow-scripts) allow_scripts=true; shift ;;
    --plan-file)   plan_file="${2:-}"; shift 2 ;;
    --plan-file=*) plan_file="${1#--plan-file=}"; shift ;;
    -h|--help)     sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "bump-manifests: unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "bump-manifests: --target must be a directory"
target="$(cd "$target" && pwd)"
[[ -n "$version" ]] || nyann::die "bump-manifests: --version is required"
[[ -n "$mode" ]]    || nyann::die "bump-manifests: --mode is required (compute|apply)"

_file_digest() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v cksum >/dev/null 2>&1; then
    cksum "$f" 2>/dev/null | awk '{print $1"-"$2}'
  fi
}

# --- resolve profile ----------------------------------------------------------

_resolve_profile() {
  if [[ -n "$profile_path" ]]; then
    [[ -f "$profile_path" ]] || nyann::die "bump-manifests: --profile file not found: $profile_path"
    echo "$profile_path"
    return 0
  fi
  local active_name="default"
  local _prefs="${HOME}/.claude/nyann/preferences.json"
  if [[ -f "$_prefs" ]] && command -v jq >/dev/null 2>&1; then
    local _pref_name
    _pref_name=$(jq -r '.default_profile // "auto-detect"' "$_prefs" 2>/dev/null || echo "auto-detect")
    if [[ "$_pref_name" != "auto-detect" && -n "$_pref_name" && "$_pref_name" != "null" ]]; then
      active_name="$_pref_name"
    fi
  fi
  if [[ "$active_name" == "default" && -f "$target/CLAUDE.md" ]]; then
    local _marker_name
    _marker_name=$(sed -n 's/.*Profile *| *\([a-z0-9][a-z0-9-]*\).*/\1/p' "$target/CLAUDE.md" 2>/dev/null | head -1)
    [[ -n "$_marker_name" ]] && active_name="$_marker_name"
  fi

  local tmp
  tmp=$(mktemp -t nyann-bump-prof.XXXXXX)
  if "${_script_dir}/../load-profile.sh" "$active_name" >"$tmp" 2>/dev/null; then
    nyann::log "bump-manifests: resolved active profile '$active_name'"
    echo "$tmp"
  else
    rm -f "$tmp"
    nyann::warn "bump-manifests: could not load active profile '$active_name'; skipping bumps"
    return 1
  fi
}

# --- compute mode -------------------------------------------------------------

_compute() {
  # Validate explicit --profile before entering subshell (nyann::die
  # inside $() only kills the subshell, not the parent).
  if [[ -n "$profile_path" ]]; then
    [[ -f "$profile_path" ]] || nyann::die "bump-manifests: --profile file not found: $profile_path"
  fi

  local resolved_profile owned_tmp=""
  resolved_profile=$(_resolve_profile) || {
    jq -n '{bumped_files:[], plan:[]}'
    return 0
  }
  [[ "$resolved_profile" == "$profile_path" ]] || owned_tmp="$resolved_profile"

  local n
  n=$(jq '.release.bump_files // [] | length' "$resolved_profile")
  if (( n == 0 )); then
    nyann::log "profile has no release.bump_files; --bump-manifests is a no-op"
    [[ -z "$owned_tmp" ]] || rm -f "$owned_tmp"
    jq -n '{bumped_files:[], plan:[]}'
    return 0
  fi

  local bumped_files_json='[]' plan_json='[]'
  local i entry path format key section command full current digest

  for ((i=0; i<n; i++)); do
    entry=$(jq -c ".release.bump_files[$i]" "$resolved_profile")
    path=$(jq -r '.path' <<<"$entry")
    format=$(jq -r '.format' <<<"$entry")

    if [[ "$path" == /* ]] || [[ "$path" =~ (^|/)\.\.?(/|$) ]]; then
      nyann::die "release.bump_files[$i].path must be repo-relative without './' or '..' segments: $path"
    fi
    nyann::assert_path_under_target "$target" "$target/$path" "release.bump_files[$i].path" >/dev/null

    full="$target/$path"
    [[ -L "$full" ]] && nyann::die "release.bump_files[$i]: refusing to bump via symlink: $full"
    [[ -f "$full" ]] || nyann::die "release.bump_files[$i]: file not found: $full"

    case "$format" in
      json-version-key)
        key=$(jq -r '.key // empty' <<<"$entry")
        [[ -n "$key" ]] || nyann::die "release.bump_files[$i]: json-version-key requires .key"
        if ! [[ "$key" =~ ^\.[A-Za-z_][A-Za-z0-9_]*(\[[0-9]+\]|\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
          nyann::die "release.bump_files[$i]: json-version-key .key must be a simple jq path — got '$key'"
        fi
        if ! jq -e "$key" "$full" >/dev/null 2>&1; then
          nyann::die "release.bump_files[$i]: json-version-key .key '$key' not present in $path"
        fi
        current=$(jq -r "$key // empty" "$full" 2>/dev/null) \
          || nyann::die "release.bump_files[$i]: jq failed reading $key from $path"
        digest=$(_file_digest "$full")
        if [[ "$current" == "$version" ]]; then
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"unchanged", from_version:$from}]' <<<"$bumped_files_json")
        else
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"bumped", from_version:$from}]' <<<"$bumped_files_json")
          plan_json=$(jq --arg p "$path" --arg fmt "$format" --arg payload "$key" --arg digest "$digest" \
            '. + [{path:$p, format:$fmt, payload:$payload, digest:$digest}]' <<<"$plan_json")
        fi
        ;;
      toml-version-key)
        section=$(jq -r '.section // empty' <<<"$entry")
        [[ -n "$section" ]] || nyann::die "release.bump_files[$i]: toml-version-key requires .section"
        current=$(awk -v sec="[$section]" '
          /^\[/ { if ($0 == sec) in_sec=1; else if (in_sec) exit; next }
          in_sec && /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]*"/ {
            match($0, /"[^"]*"/); print substr($0, RSTART+1, RLENGTH-2); exit
          }' "$full")
        [[ -n "$current" ]] \
          || nyann::die "release.bump_files[$i]: could not find single-line \`version = \"...\"\` in [$section] of $path"
        digest=$(_file_digest "$full")
        if [[ "$current" == "$version" ]]; then
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"unchanged", from_version:$from}]' <<<"$bumped_files_json")
        else
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"bumped", from_version:$from}]' <<<"$bumped_files_json")
          plan_json=$(jq --arg p "$path" --arg fmt "$format" --arg payload "$section" --arg digest "$digest" \
            '. + [{path:$p, format:$fmt, payload:$payload, digest:$digest}]' <<<"$plan_json")
        fi
        ;;
      yaml-version-key)
        # Helm Chart.yaml: bump the top-level `version:` (the chart's own
        # SemVer — this drives the chart tag). Optionally mirror the paired
        # app's release tag into `appVersion:` when .app_version is true (per
        # I7/I10 spec: appVersion tracks the deployed app, not the chart). The
        # key is line-oriented YAML, so we extract/replace with awk mirroring
        # toml-version-key, NOT a YAML parser (no PyYAML dependency at bump time).
        local app_version_flag yaml_payload
        app_version_flag=$(jq -r 'if (.app_version // false) then "true" else "false" end' <<<"$entry")
        current=$(awk '
          /^[[:space:]]*#/ { next }
          /^version[[:space:]]*:/ {
            sub(/^version[[:space:]]*:[[:space:]]*/, "")
            gsub(/^["'\'']|["'\'']$/, "")
            sub(/[[:space:]]*(#.*)?$/, "")
            print; exit
          }' "$full")
        [[ -n "$current" ]] \
          || nyann::die "release.bump_files[$i]: could not find a top-level \`version:\` key in $path"
        digest=$(_file_digest "$full")
        # payload encodes whether appVersion is also bumped: "version" or
        # "version+appVersion". The apply arm dispatches on this.
        if [[ "$app_version_flag" == "true" ]]; then
          yaml_payload="version+appVersion"
        else
          yaml_payload="version"
        fi
        if [[ "$current" == "$version" ]]; then
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"unchanged", from_version:$from}]' <<<"$bumped_files_json")
        else
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"bumped", from_version:$from}]' <<<"$bumped_files_json")
          plan_json=$(jq --arg p "$path" --arg fmt "$format" --arg payload "$yaml_payload" --arg digest "$digest" \
            '. + [{path:$p, format:$fmt, payload:$payload, digest:$digest}]' <<<"$plan_json")
        fi
        ;;
      text-version)
        # Terraform module VERSION file (or any whole-file version sentinel):
        # the entire file content IS the version. No in-file key to bump — we
        # overwrite the file with the new version. Read current as the first
        # non-blank line so a trailing newline doesn't count as drift.
        current=$(awk 'NF { sub(/[[:space:]]+$/, ""); print; exit }' "$full")
        digest=$(_file_digest "$full")
        if [[ "$current" == "$version" ]]; then
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"unchanged", from_version:$from}]' <<<"$bumped_files_json")
        else
          bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" --arg from "$current" \
            '. + [{path:$p, format:$fmt, action:"bumped", from_version:$from}]' <<<"$bumped_files_json")
          plan_json=$(jq --arg p "$path" --arg fmt "$format" --arg payload "text" --arg digest "$digest" \
            '. + [{path:$p, format:$fmt, payload:$payload, digest:$digest}]' <<<"$plan_json")
        fi
        ;;
      script)
        command=$(jq -r '.command // empty' <<<"$entry")
        [[ -n "$command" ]] || nyann::die "release.bump_files[$i]: script requires .command"
        if ! $allow_scripts; then
          nyann::die "release.bump_files[$i]: script format requires --allow-scripts (executes arbitrary shell commands from profile)"
        fi
        if ! $dry_run; then
          nyann::warn "release.bump_files[$i]: script format will execute shell command: $command"
        fi
        digest=$(_file_digest "$full")
        bumped_files_json=$(jq --arg p "$path" --arg fmt "$format" \
          '. + [{path:$p, format:$fmt, action:"bumped", from_version:null}]' <<<"$bumped_files_json")
        plan_json=$(jq --arg p "$path" --arg fmt "$format" --arg payload "$command" --arg digest "$digest" \
          '. + [{path:$p, format:$fmt, payload:$payload, digest:$digest}]' <<<"$plan_json")
        ;;
      *)
        nyann::die "release.bump_files[$i]: unknown format: $format"
        ;;
    esac
  done

  [[ -z "$owned_tmp" ]] || rm -f "$owned_tmp"
  jq -n --argjson files "$bumped_files_json" --argjson plan "$plan_json" \
    '{bumped_files:$files, plan:$plan}'
}

# --- apply mode ---------------------------------------------------------------

_apply() {
  [[ -n "$plan_file" ]] || nyann::die "bump-manifests --mode apply: --plan-file is required"
  [[ -f "$plan_file" ]] || nyann::die "bump-manifests --mode apply: plan file not found: $plan_file"

  local n applied=0
  n=$(jq '.plan | length' "$plan_file")
  if (( n == 0 )); then
    jq -n '{applied:0}'
    return 0
  fi

  local i path format payload digest_at_compute digest_now full tmp
  for ((i=0; i<n; i++)); do
    path=$(jq -r ".plan[$i].path" "$plan_file")
    format=$(jq -r ".plan[$i].format" "$plan_file")
    payload=$(jq -r ".plan[$i].payload" "$plan_file")
    digest_at_compute=$(jq -r ".plan[$i].digest" "$plan_file")
    full="$target/$path"

    if [[ -n "$digest_at_compute" ]]; then
      digest_now=$(_file_digest "$full")
      if [[ "$digest_now" != "$digest_at_compute" ]]; then
        nyann::die "bump-manifests: $path changed between compute and apply (digest mismatch); refusing to mutate stale plan."
      fi
    else
      nyann::warn "bump-manifests: no digest tool on PATH; TOCTOU re-check disabled for $path"
    fi

    case "$format" in
      json-version-key)
        tmp=$(mktemp -t nyann-bump-json.XXXXXX)
        if jq --arg v "$version" "$payload = \$v" "$full" > "$tmp"; then
          mv "$tmp" "$full"
        else
          rm -f "$tmp"
          nyann::die "bump-manifests: jq failed setting $payload in $path"
        fi
        ;;
      toml-version-key)
        tmp=$(mktemp -t nyann-bump-toml.XXXXXX)
        awk -v sec="[$payload]" -v new="$version" '
          /^\[/ {
            if ($0 == sec) in_sec=1
            else if (in_sec) in_sec=0
            print; next
          }
          in_sec && !done && /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]*"/ {
            sub(/"[^"]*"/, "\"" new "\"")
            done = 1
          }
          { print }
        ' "$full" > "$tmp"
        mv "$tmp" "$full"
        ;;
      yaml-version-key)
        # Rewrite the top-level `version:` line. When payload requests it,
        # also rewrite `appVersion:` to mirror the app's release tag. We touch
        # ONLY the first top-level occurrence of each key (in-section/nested
        # keys are indented and skipped by the `^version:` / `^appVersion:`
        # left-anchor), leaving every other field untouched.
        tmp=$(mktemp -t nyann-bump-yaml.XXXXXX)
        awk -v new="$version" -v bump_app="$payload" '
          BEGIN { vdone=0; adone=0 }
          !vdone && /^version[[:space:]]*:/ {
            match($0, /^version[[:space:]]*:[[:space:]]*/)
            pre = substr($0, 1, RLENGTH)
            print pre new
            vdone=1
            next
          }
          (bump_app == "version+appVersion") && !adone && /^appVersion[[:space:]]*:/ {
            match($0, /^appVersion[[:space:]]*:[[:space:]]*/)
            pre = substr($0, 1, RLENGTH)
            print pre "\"" new "\""
            adone=1
            next
          }
          { print }
        ' "$full" > "$tmp"
        mv "$tmp" "$full"
        ;;
      text-version)
        # Whole-file version sentinel (terraform VERSION): overwrite with the
        # new version + trailing newline.
        tmp=$(mktemp -t nyann-bump-text.XXXXXX)
        printf '%s\n' "$version" > "$tmp"
        mv "$tmp" "$full"
        ;;
      script)
        if ! $allow_scripts; then
          nyann::die "bump-manifests apply: script format requires --allow-scripts"
        fi
        if ! ( cd "$target" && NEW_VERSION="$version" bash -c "$payload" ); then
          nyann::die "bump-manifests: script command failed for $path: $payload"
        fi
        ;;
    esac
    ((applied++)) || true
  done

  jq -n --argjson applied "$applied" '{applied:$applied}'
}

# --- dispatch -----------------------------------------------------------------

case "$mode" in
  compute) _compute ;;
  apply)   _apply ;;
  *) nyann::die "bump-manifests: --mode must be compute or apply" ;;
esac
