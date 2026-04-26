#!/usr/bin/env bash
# gen-templates.sh — generate GitHub PR and issue templates from profile.
#
# Usage:
#   gen-templates.sh --profile <path> --stack <path> --target <repo>
#                    [--allow-merge-existing] [--dry-run]
#                    [--force]   # alias for --allow-merge-existing (legacy)
#
# Writes .github/PULL_REQUEST_TEMPLATE.md and .github/ISSUE_TEMPLATE/
# files, wrapped in `<!-- nyann:templates:start/end -->` markers (HTML
# comments are valid in Markdown and render as nothing on GitHub).
#
# Re-run semantics:
#   - File doesn't exist → write fresh.
#   - File exists with nyann markers → replace between markers
#     (idempotent; user content outside markers preserved).
#   - File exists WITHOUT markers → refuse, log "user content present;
#     pass --allow-merge-existing to append a marked block instead".
#     With --allow-merge-existing, the marked block is appended; the
#     user's pre-existing content stays in place.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
stack_path=""
allow_merge=false
dry_run=false

MARKER_START="<!-- nyann:templates:start -->"
MARKER_END="<!-- nyann:templates:end -->"

# shellcheck disable=SC2034  # stack_path: accepted for bootstrap compat, not used
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)                 target="${2:-}"; shift 2 ;;
    --target=*)               target="${1#--target=}"; shift ;;
    --profile)                profile_path="${2:-}"; shift 2 ;;
    --profile=*)              profile_path="${1#--profile=}"; shift ;;
    --stack)                  stack_path="${2:-}"; shift 2 ;;
    --stack=*)                stack_path="${1#--stack=}"; shift ;;
    --allow-merge-existing)   allow_merge=true; shift ;;
    --force)                  allow_merge=true; shift ;;
    --dry-run)                dry_run=true; shift ;;
    -h|--help)                sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
target="$(cd "$target" && pwd)"

profile_json="$(cat "$profile_path")"
templates_dir="${_script_dir}/../templates/github"

# --- Build checklist from hook phases ----------------------------------------

checklist=""
hooks_pre_commit=$(jq -r '.hooks.pre_commit // [] | .[]' <<<"$profile_json")

while IFS= read -r hook; do
  [[ -z "$hook" ]] && continue
  case "$hook" in
    eslint)              checklist="${checklist}- [ ] Lint passes (\`eslint\`)"$'\n' ;;
    biome)               checklist="${checklist}- [ ] Lint passes (\`biome\`)"$'\n' ;;
    prettier)            checklist="${checklist}- [ ] Code is formatted (\`prettier\`)"$'\n' ;;
    ruff)                checklist="${checklist}- [ ] Lint passes (\`ruff check\`)"$'\n' ;;
    ruff-format)         checklist="${checklist}- [ ] Code is formatted (\`ruff format\`)"$'\n' ;;
    black)               checklist="${checklist}- [ ] Code is formatted (\`black\`)"$'\n' ;;
    mypy)                checklist="${checklist}- [ ] Type check passes (\`mypy\`)"$'\n' ;;
    gofmt)               checklist="${checklist}- [ ] Code is formatted (\`gofmt\`)"$'\n' ;;
    go-vet)              checklist="${checklist}- [ ] Vet passes (\`go vet\`)"$'\n' ;;
    golangci-lint)       checklist="${checklist}- [ ] Lint passes (\`golangci-lint\`)"$'\n' ;;
    fmt|rustfmt)         checklist="${checklist}- [ ] Code is formatted (\`cargo fmt\`)"$'\n' ;;
    clippy)              checklist="${checklist}- [ ] Clippy passes (\`cargo clippy\`)"$'\n' ;;
    stylelint)           checklist="${checklist}- [ ] Style lint passes (\`stylelint\`)"$'\n' ;;
  esac
done <<<"$hooks_pre_commit"

hooks_pre_push=$(jq -r '.hooks.pre_push // [] | .[]' <<<"$profile_json")
while IFS= read -r hook; do
  [[ -z "$hook" ]] && continue
  case "$hook" in
    jest|vitest|pytest)  checklist="${checklist}- [ ] Tests pass (\`${hook}\`)"$'\n' ;;
  esac
done <<<"$hooks_pre_push"

if [[ -z "$checklist" ]]; then
  checklist="- [ ] Lint passes"$'\n'"- [ ] Tests pass"$'\n'
fi

# --- Build scope section from conventions ------------------------------------

scope_section=""
commit_scopes=$(jq -r '.conventions.commit_scopes // [] | .[]' <<<"$profile_json")
if [[ -n "$commit_scopes" ]]; then
  scope_section="## Scope"$'\n'$'\n'"Affected area (from commit scopes):"$'\n'
  while IFS= read -r scope; do
    [[ -z "$scope" ]] && continue
    scope_section="${scope_section}- [ ] \`${scope}\`"$'\n'
  done <<<"$commit_scopes"
fi

# --- Write templates ---------------------------------------------------------

# Wrap content in nyann markers. For files with YAML frontmatter
# (`---\n...\n---\n`), insert the start marker AFTER the frontmatter so
# GitHub still parses the metadata block. The end marker always lands
# at the bottom.
wrap_with_markers() {
  local body="$1"
  if [[ "$body" == "---"$'\n'* ]]; then
    # Find the second `---` line — end of frontmatter.
    local frontmatter
    frontmatter=$(printf '%s\n' "$body" | awk '
      NR == 1 && /^---$/ { print; in_fm = 1; next }
      in_fm && /^---$/   { print; exit }
      in_fm              { print }
    ')
    local rest="${body#"$frontmatter"}"
    # Strip leading newline from rest if present.
    rest="${rest#$'\n'}"
    printf '%s\n%s\n%s\n%s\n' "$frontmatter" "$MARKER_START" "$rest" "$MARKER_END"
  else
    printf '%s\n%s\n%s\n' "$MARKER_START" "$body" "$MARKER_END"
  fi
}

write_template() {
  local src="$1" dest="$2" label="$3"

  if [[ "$dry_run" == "true" ]]; then
    nyann::log "DRY-RUN: would write $label → $dest"
    return 0
  fi

  if [[ -L "$dest" ]]; then
    nyann::die "refusing to write $label via symlink: $dest"
  fi

  local content
  content=$(cat "$src")
  content="${content//\{\{ checklist \}\}/$checklist}"
  content="${content//\{\{ scope_section \}\}/$scope_section}"

  local marked
  marked=$(wrap_with_markers "$content")

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    if grep -Fq "$MARKER_START" "$dest" && grep -Fq "$MARKER_END" "$dest"; then
      # Marker-bracketed file: drop the existing marked block, then
      # append the freshly-marked one. Two-pass keeps the awk script
      # free of multi-line variable interpolation (which trips
      # `awk -v` on embedded newlines).
      local tmp preamble
      tmp=$(mktemp -t nyann-tmpl.XXXXXX)
      preamble=$(awk -v start="$MARKER_START" -v end="$MARKER_END" '
        index($0, start) { in_block = 1; next }
        index($0, end)   { in_block = 0; next }
        !in_block        { print }
      ' "$dest")
      {
        if [[ -n "$preamble" ]]; then
          printf '%s\n' "$preamble"
        fi
        printf '%s\n' "$marked"
      } > "$tmp"
      mv "$tmp" "$dest"
      nyann::log "regenerated $label (markers preserved): $dest"
    elif $allow_merge; then
      # Append marked block to the end so user-written content above
      # stays intact. The marked block carries its own markers so a
      # subsequent re-run will detect and replace it cleanly.
      printf '\n%s\n' "$marked" >> "$dest"
      nyann::warn "appended marked block to existing $label (user content above preserved): $dest"
    else
      nyann::warn "skip $label (file exists without nyann markers): $dest"
      nyann::warn "  pass --allow-merge-existing to append a marked block (preserves your content)"
      return 0
    fi
  else
    printf '%s\n' "$marked" > "$dest"
    nyann::log "wrote $label: $dest"
  fi
}

pr_src="${templates_dir}/PULL_REQUEST_TEMPLATE.md"
[[ -f "$pr_src" ]] || nyann::die "PR template not found: $pr_src"

write_template "$pr_src" "$target/.github/PULL_REQUEST_TEMPLATE.md" "PR template"

for issue_tmpl in "${templates_dir}/ISSUE_TEMPLATE"/*; do
  fname=$(basename "$issue_tmpl")
  write_template "$issue_tmpl" "$target/.github/ISSUE_TEMPLATE/$fname" "Issue template ($fname)"
done
