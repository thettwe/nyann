#!/usr/bin/env bash
# track-claudemd-usage.sh — Claude Code PostToolUse hook for CLAUDE.md usage tracking.
#
# Usage: Wired via hooks/hooks.json as a PostToolUse handler.
#
# Tracks which docs are read and which commands are run, writing to
# memory/claudemd-usage.json. Opt-in: only tracks if that file exists.
# Lightweight: reads stdin JSON, does one jq merge, exits.
#
# Input (stdin): Claude Code PostToolUse JSON payload with tool_name,
# tool_input, and tool_result fields.

set -e
set -u
set -o pipefail

# Resolve repo root — walk up from PWD looking for .git
find_repo_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -d "$dir/.git" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

repo_root=$(find_repo_root 2>/dev/null) || exit 0
usage_file="$repo_root/memory/claudemd-usage.json"

# Opt-in guard: only track if usage file exists
[[ -f "$usage_file" ]] || exit 0

# Need jq
command -v jq >/dev/null 2>&1 || exit 0

# Read stdin
stdin_blob=""
if [[ ! -t 0 ]]; then
  stdin_blob="$(cat || true)"
fi
[[ -n "$stdin_blob" ]] || exit 0

tool_name=$(jq -r '.tool_name // empty' <<<"$stdin_blob" 2>/dev/null || true)
[[ -n "$tool_name" ]] || exit 0

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Parse CLAUDE.md for doc references and commands
claudemd="$repo_root/CLAUDE.md"

update_key=""
update_section=""

case "$tool_name" in
  Read)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$stdin_blob" 2>/dev/null || true)
    [[ -n "$file_path" ]] || exit 0

    # Normalize to relative path
    rel_path="${file_path#"$repo_root"/}"
    [[ "$rel_path" != "$file_path" ]] || exit 0

    # Only track docs referenced in CLAUDE.md
    if [[ -f "$claudemd" ]] && grep -Fq "$rel_path" "$claudemd" 2>/dev/null; then
      update_key="docs_read"
      update_section="$rel_path"
    fi
    ;;
  Bash)
    command_str=$(jq -r '.tool_input.command // empty' <<<"$stdin_blob" 2>/dev/null || true)
    [[ -n "$command_str" ]] || exit 0

    # Only track commands referenced in CLAUDE.md
    if [[ -f "$claudemd" ]] && grep -Fq "$command_str" "$claudemd" 2>/dev/null; then
      update_key="commands_run"
      update_section="$command_str"
    fi
    ;;
  *)
    exit 0
    ;;
esac

[[ -n "$update_key" && -n "$update_section" ]] || exit 0

# Session tracking: increment sessions once per Claude Code session.
# Use a marker file with the parent PID — same PPID means same session.
session_marker="$repo_root/memory/.claudemd-session-${PPID:-$$}"
bump_session=false
if [[ ! -f "$session_marker" ]]; then
  # Clean stale markers from previous sessions
  find "$repo_root/memory" -maxdepth 1 -name '.claudemd-session-*' -mmin +120 -delete 2>/dev/null || true
  touch "$session_marker" 2>/dev/null || true
  bump_session=true
fi

# Acquire a short-timeout advisory lock around the read-modify-write.
# Without this, two PostToolUse hooks firing concurrently both read the
# same baseline JSON, both compute increments from it, and the second
# `mv` clobbers the first — losing every increment in the first batch.
# Failing to acquire the lock skips this firing rather than blocking
# the Claude Code hook chain (one lost increment is preferable to a
# stuck tool call).
lockdir="${usage_file}.lockdir"
tmp_file=$(mktemp -t "nyann-usage.XXXXXX")
acquired=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if mkdir "$lockdir" 2>/dev/null; then
    acquired=true; break
  fi
  sleep 0.1
done

cleanup() {
  rm -f "$tmp_file"
  $acquired && rmdir "$lockdir" 2>/dev/null || true
}
trap cleanup EXIT

if ! $acquired; then
  exit 0
fi

jq --arg key "$update_key" --arg section "$update_section" --arg ts "$timestamp" \
  --argjson bump_session "$([ "$bump_session" = true ] && echo 1 || echo 0)" '
  (if $bump_session == 1 then .sessions = ((.sessions // 0) + 1) else . end) |
  .[$key][$section] = ((.[$key][$section] // 0) + 1) |
  if $key == "docs_read" then
    .sections[$section] = {
      referenced: ((.sections[$section].referenced // 0) + 1),
      last_referenced: $ts
    }
  else . end
' "$usage_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$usage_file"
