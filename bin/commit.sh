#!/usr/bin/env bash
# commit.sh — gather context for the commit skill.
#
# Usage:
#   commit.sh --target <repo> [--max-diff-bytes N]
#
# Reads `git diff --staged`, detects the active commit convention, and
# emits a context JSON on stdout that the skill layer feeds to the LLM:
#
#   {
#     "target":       "/abs/path/to/repo",
#     "branch":       "feat/foo",
#     "on_main":      false,
#     "convention":   "conventional-commits" | "commitizen" | "default",
#     "convention_source": "commitlint.config.js" | "pre-commit.com" | "default",
#     "staged_files": ["src/app.ts", "..."],
#     "insertions":   23,
#     "deletions":    5,
#     "summary":      "one-line numstat-style summary",
#     "diff":         "<staged diff; truncated to max-diff-bytes>",
#     "truncated":    false
#   }
#
# Exit codes:
#   0 — context emitted, ready for generation
#   2 — target not a git repo
#   3 — nothing staged (prompts caller to stage first)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target="$PWD"
max_diff_bytes=60000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --max-diff-bytes)  max_diff_bytes="${2:-60000}"; shift 2 ;;
    --max-diff-bytes=*) max_diff_bytes="${1#--max-diff-bytes=}"; shift ;;
    -h|--help)         sed -n '3,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -d "$target" ]] || nyann::die "--target must be a directory"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || { nyann::warn "$target is not a git repo"; exit 2; }

# --- branch + on_main --------------------------------------------------------

branch="$(git -C "$target" branch --show-current 2>/dev/null || echo '')"
on_main=false
case "$branch" in main|master) on_main=true ;; esac

# --- staged diff -------------------------------------------------------------

diff_text=$(git -C "$target" diff --staged)
if [[ -z "$diff_text" ]]; then
  nyann::warn "no staged changes in $target — run \`git add\` first"
  exit 3
fi

# numstat summary (files + insertions + deletions). Portable loop so bash
# 3.2 (macOS default) doesn't choke on `mapfile`.
staged_files=()
while IFS= read -r _line; do
  staged_files+=("$_line")
done < <(git -C "$target" diff --staged --name-only)
stats=$(git -C "$target" diff --staged --numstat | awk '
  { ins += $1; del += $2 }
  END { printf "%d %d", ins, del }
')
insertions="${stats% *}"
deletions="${stats#* }"
n_files=${#staged_files[@]}

# Short summary line for the prompt — one per file, with net +/-.
summary=$(git -C "$target" diff --staged --numstat | awk '
  { printf "%s: +%s/-%s\n", $3, $1, $2 }
')

# --- truncate oversized diffs ------------------------------------------------

diff_bytes=${#diff_text}
truncated=false
if (( diff_bytes > max_diff_bytes )); then
  diff_text="${diff_text:0:$max_diff_bytes}"
  diff_text+=$'\n\n[... truncated; '"$((diff_bytes - max_diff_bytes))"' bytes omitted ...]'
  truncated=true
fi

# --- detect commit convention ------------------------------------------------
# Priority: commitlint.config.* > pre-commit.com config with commitizen hook
#           > default (built-in conventional-commits regex).

convention="default"
convention_source="default"

if compgen -G "$target/commitlint.config*" >/dev/null 2>&1; then
  convention="conventional-commits"
  convention_source="commitlint.config.js"
fi
if [[ -f "$target/.pre-commit-config.yaml" ]]; then
  if grep -q 'commitizen' "$target/.pre-commit-config.yaml" 2>/dev/null; then
    # commitizen enforces CC by default; label specifically so the prompt can
    # nudge users that commitizen's stricter body/footer rules apply.
    convention="commitizen"
    convention_source="pre-commit.com"
  fi
fi

# --- emit --------------------------------------------------------------------

files_json=$(printf '%s\n' "${staged_files[@]}" | jq -R . | jq -s .)

jq -n \
  --arg target "$target" \
  --arg branch "$branch" \
  --argjson on_main "$on_main" \
  --arg convention "$convention" \
  --arg convention_source "$convention_source" \
  --argjson staged_files "$files_json" \
  --argjson insertions "$insertions" \
  --argjson deletions "$deletions" \
  --argjson n_files "$n_files" \
  --arg summary "$summary" \
  --arg diff "$diff_text" \
  --argjson truncated "$truncated" \
  '{
    target: $target,
    branch: $branch,
    on_main: $on_main,
    convention: $convention,
    convention_source: $convention_source,
    staged_files: $staged_files,
    n_files: $n_files,
    insertions: $insertions,
    deletions: $deletions,
    summary: $summary,
    diff: $diff,
    truncated: $truncated
  }'
