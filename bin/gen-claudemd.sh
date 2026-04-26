#!/usr/bin/env bash
# gen-claudemd.sh — emit a router-mode CLAUDE.md for the target repo.
#
# Usage:
#   gen-claudemd.sh --profile <path> --doc-plan <path>
#                   [--stack <path>] [--project-name <name>]
#                   [--target <repo-root>] [--force]
#
# Writes (or merges into) $target/CLAUDE.md a nyann-managed block delimited
# by `<!-- nyann:start -->` and `<!-- nyann:end -->`. Content outside the
# markers is preserved verbatim. If the file exists without markers, the
# generated block is appended with an explanatory note.
#
# Size budgets:
#   soft 3 KB → warn
#   hard 8 KB → refuse unless --force
#
# The block is assembled programmatically rather than via a template with
# loops — keeps the renderer in bash without pulling in a templater.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

profile_path=""
plan_path=""
stack_path=""
workspace_configs_path=""
extra_scopes_path=""
project_name=""
target_root="$PWD"
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)         profile_path="${2:-}"; shift 2 ;;
    --profile=*)       profile_path="${1#--profile=}"; shift ;;
    --doc-plan)        plan_path="${2:-}"; shift 2 ;;
    --doc-plan=*)      plan_path="${1#--doc-plan=}"; shift ;;
    --stack)           stack_path="${2:-}"; shift 2 ;;
    --stack=*)         stack_path="${1#--stack=}"; shift ;;
    --workspace-configs)  workspace_configs_path="${2:-}"; shift 2 ;;
    --workspace-configs=*) workspace_configs_path="${1#--workspace-configs=}"; shift ;;
    --extra-scopes)        extra_scopes_path="${2:-}"; shift 2 ;;
    --extra-scopes=*)      extra_scopes_path="${1#--extra-scopes=}"; shift ;;
    --project-name)    project_name="${2:-}"; shift 2 ;;
    --project-name=*)  project_name="${1#--project-name=}"; shift ;;
    --target)          target_root="${2:-}"; shift 2 ;;
    --target=*)        target_root="${1#--target=}"; shift ;;
    --force)           force=true; shift ;;
    -h|--help)         sed -n '3,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required (got: $profile_path)"
[[ -n "$plan_path" && -f "$plan_path" ]] || nyann::die "--doc-plan <path> is required (got: $plan_path)"
[[ -d "$target_root" ]] || nyann::die "target is not a directory: $target_root"
target_root="$(cd "$target_root" && pwd)"

[[ -n "$project_name" ]] || project_name="$(basename "$target_root")"

profile_json="$(cat "$profile_path")"
plan_json="$(cat "$plan_path")"

# --- stack context -----------------------------------------------------------

stack_language="unknown"
stack_framework="(none)"
stack_pkgmgr="(none)"
stack_monorepo=false

if [[ -n "$stack_path" && -f "$stack_path" ]]; then
  stack_language="$(jq -r '.primary_language // "unknown"' "$stack_path")"
  v=$(jq -r '.framework // "null"' "$stack_path");       [[ "$v" != "null" ]] && stack_framework="$v" || stack_framework="(none)"
  v=$(jq -r '.package_manager // "null"' "$stack_path"); [[ "$v" != "null" ]] && stack_pkgmgr="$v"    || stack_pkgmgr="(none)"
  stack_monorepo="$(jq -r '.is_monorepo // false' "$stack_path")"
fi

# --- commands derived from package manager ----------------------------------

install_cmd=""; run_cmd=""; test_cmd=""; lint_cmd=""
case "$stack_pkgmgr" in
  pnpm) install_cmd="pnpm install"; run_cmd="pnpm dev";   test_cmd="pnpm test";  lint_cmd="pnpm lint" ;;
  yarn) install_cmd="yarn";          run_cmd="yarn dev";   test_cmd="yarn test";  lint_cmd="yarn lint" ;;
  bun)  install_cmd="bun install";   run_cmd="bun dev";    test_cmd="bun test";   lint_cmd="bun lint"  ;;
  npm)  install_cmd="npm install";   run_cmd="npm run dev";test_cmd="npm test";   lint_cmd="npm run lint" ;;
  poetry) install_cmd="poetry install"; run_cmd="(see your entry point)"; test_cmd="poetry run pytest"; lint_cmd="poetry run ruff check ." ;;
  uv)     install_cmd="uv sync";        run_cmd="(see your entry point)"; test_cmd="uv run pytest";     lint_cmd="uv run ruff check ." ;;
  pip)    install_cmd="pip install -r requirements.txt"; run_cmd="(see your entry point)"; test_cmd="pytest"; lint_cmd="ruff check ." ;;
  pipenv) install_cmd="pipenv install"; run_cmd="(see your entry point)"; test_cmd="pipenv run pytest"; lint_cmd="pipenv run ruff check ." ;;
  *)    install_cmd="(configure)"; run_cmd="(configure)"; test_cmd="(configure)"; lint_cmd="(configure)" ;;
esac

# --- workspace table rows ---------------------------------------------------

ws_table_rows=""
max_ws_rows=10

if [[ -n "$workspace_configs_path" && -f "$workspace_configs_path" ]]; then
  ws_json=$(cat "$workspace_configs_path")
  ws_total=$(jq 'length' <<<"$ws_json")
  ws_show=$(( ws_total < max_ws_rows ? ws_total : max_ws_rows ))

  for (( wi=0; wi<ws_show; wi++ )); do
    ws=$(jq -c ".[$wi]" <<<"$ws_json")
    ws_path=$(nyann::safe_md_cell "$(jq -r '.path' <<<"$ws")")
    ws_lang=$(nyann::safe_md_cell "$(jq -r '.primary_language // "unknown"' <<<"$ws")")
    ws_fw=$(jq -r '.framework // ""' <<<"$ws")
    [[ "$ws_fw" == "null" || -z "$ws_fw" ]] && ws_fw="—"
    ws_fw=$(nyann::safe_md_cell "$ws_fw")

    ws_pm=$(jq -r '.package_manager // ""' <<<"$ws")
    ws_cmds=""
    case "$ws_pm" in
      pnpm) ws_cmds="pnpm dev, pnpm test, pnpm lint" ;;
      yarn) ws_cmds="yarn dev, yarn test, yarn lint" ;;
      npm)  ws_cmds="npm run dev, npm test, npm run lint" ;;
      bun)  ws_cmds="bun dev, bun test, bun lint" ;;
      uv)   ws_cmds="uv run pytest, uv run ruff check ." ;;
      poetry) ws_cmds="poetry run pytest, poetry run ruff check ." ;;
      pip)  ws_cmds="pytest, ruff check ." ;;
      cargo) ws_cmds="cargo build, cargo test, cargo clippy" ;;
      go)   ws_cmds="go build, go test, go vet" ;;
      *)    ws_cmds="—" ;;
    esac
    ws_cmds=$(nyann::safe_md_cell "$ws_cmds")

    ws_table_rows+="| ${ws_path} | ${ws_lang} | ${ws_fw} | ${ws_cmds} |"$'\n'
  done

  if (( ws_total > max_ws_rows )); then
    ws_remaining=$(( ws_total - max_ws_rows ))
    ws_table_rows+="| … | +${ws_remaining} more | — | — |"$'\n'
  fi
fi

# --- branching summary ------------------------------------------------------

strategy=$(jq -r '.branching.strategy // "github-flow"' <<<"$profile_json")
branching_summary=""
case "$strategy" in
  github-flow) branching_summary="GitHub Flow. Feature branches from main; PR to merge; main is deployable." ;;
  gitflow)     branching_summary="GitFlow. Features target develop; release branches cut from develop; hotfixes on main." ;;
  trunk-based) branching_summary="Trunk-based. Short-lived branches; protected main; feature flags over long branches." ;;
  *) branching_summary="$strategy" ;;
esac

commit_format=$(jq -r '.conventions.commit_format // "conventional-commits"' <<<"$profile_json")
case "$commit_format" in
  conventional-commits) commit_convention="Conventional Commits"; commit_example="feat(api): add /healthz endpoint" ;;
  *) commit_convention="$commit_format"; commit_example="(see CONTRIBUTING.md)" ;;
esac

# --- docs map ---------------------------------------------------------------
# Build rows from the DocumentationPlan. Each target becomes a table row.

docs_rows=""
while IFS= read -r key; do
  ttype=$(jq -r --arg k "$key" '.targets[$k].type // ""' <<<"$plan_json")
  case "$ttype" in
    local)    link=$(jq -r --arg k "$key" '.targets[$k].path // ""' <<<"$plan_json"); link="./$link" ;;
    obsidian) link=$(jq -r --arg k "$key" '.targets[$k].link_in_claude_md // (.targets[$k].path // "obsidian://")' <<<"$plan_json") ;;
    notion)   link=$(jq -r --arg k "$key" '.targets[$k].link_in_claude_md // (.targets[$k].url // "notion://")' <<<"$plan_json") ;;
    *)        continue ;;
  esac

  case "$key" in
    architecture) label="Architecture" ;;
    prd)          label="PRD" ;;
    adrs)         label="Decisions (ADRs)" ;;
    research)     label="Research" ;;
    memory)       label="Memory" ;;
    *)            label="$key" ;;
  esac

  # Sanitize the $link cell — DocumentationPlan's
  # `link_in_claude_md` is a free-form string. Without escaping,
  # a value containing `|` breaks the Markdown table, and one
  # containing `<!-- nyann:end -->` / `-->` prematurely closes the
  # managed-block marker region. Content outside the markers is
  # preserved verbatim on regeneration, giving an attacker a
  # persistence mechanism.
  #
  # The link is interpolated into both positions of `[text](target)`.
  # `safe_md_cell` closes the table-cell and marker vectors but leaves
  # `)` alone; a legitimate value like `https://wiki/(v2)/page` or an
  # attacker-shaped `foo) evil` still breaks the link target. Use
  # `safe_md_link_target` for the target position so `(` `)` get
  # percent-encoded to `%28` `%29`; keep `safe_md_cell` for the
  # visible-text position where percent-encoded parens would render as
  # literal noise.
  link_text=$(nyann::safe_md_cell "$link")
  link_target=$(nyann::safe_md_link_target "$link")
  label_safe=$(nyann::safe_md_cell "$label")
  docs_rows+="| **${label_safe}** | [${link_text}](${link_target}) |"$'\n'
done < <(jq -r '.targets | keys_unsorted[]' <<<"$plan_json")

# --- memory path from plan --------------------------------------------------
mem_path="memory"
memtype=$(jq -r '.targets.memory.type // ""' <<<"$plan_json")
if [[ "$memtype" == "local" ]]; then
  mem_path=$(jq -r '.targets.memory.path // "memory"' <<<"$plan_json")
fi

profile_name=$(jq -r '.name // "default"' <<<"$profile_json")
storage_strategy=$(jq -r '.storage_strategy // "local"' <<<"$plan_json")
today="$(date +%Y-%m-%d)"

# Sanitize every user-controlled value that lands in the heredoc
# *before* the rows that interpolate them are built. A hand-crafted
# profile with `branching.strategy` = `github-flow<!-- nyann:end -->`
# could close the nyann marker block early and gain persistence in the
# content-outside-markers region on regen. Sanitizing once here,
# up-front, means both tables see the safe value and no new call-site
# can forget the wrap.
project_name=$(nyann::safe_md_cell "$project_name")
stack_language=$(nyann::safe_md_cell "$stack_language")
stack_framework=$(nyann::safe_md_cell "$stack_framework")
stack_pkgmgr=$(nyann::safe_md_cell "$stack_pkgmgr")
stack_monorepo=$(nyann::safe_md_cell "$stack_monorepo")
install_cmd=$(nyann::safe_md_cell "$install_cmd")
run_cmd=$(nyann::safe_md_cell "$run_cmd")
test_cmd=$(nyann::safe_md_cell "$test_cmd")
lint_cmd=$(nyann::safe_md_cell "$lint_cmd")
branching_summary=$(nyann::safe_md_cell "$branching_summary")
commit_convention=$(nyann::safe_md_cell "$commit_convention")
commit_example=$(nyann::safe_md_cell "$commit_example")
# mem_path is used in *two* positions in the Memory heredoc:
#   [`${mem_path}/`](./${mem_path}/README.md)
# The first is inside a code span (backticks) nested in the link text
# — backticks in the value break the code span, so we substitute them
# with single quotes. The second is the link target — `)` in the value
# breaks the link, so we percent-encode parens. Keep the two shapes in
# separate variables so the user-visible code span stays readable
# (literal `/`, no `%28` noise) while the URL stays correctly escaped.
# Target-position variant: percent-encodes parens for URL safety.
mem_path_cell=$(printf '%s' "$mem_path" | tr -d '\r\n' | sed -e 's/<!--/\&lt;!--/g' -e 's/-->/--\&gt;/g' -e 's/`/'"'"'/g')
mem_path_target=$(nyann::safe_md_link_target "$mem_path_cell")
mem_path="$mem_path_cell"
profile_name=$(nyann::safe_md_cell "$profile_name")
storage_strategy=$(nyann::safe_md_cell "$storage_strategy")

# --- conventions rows -------------------------------------------------------
# Built AFTER bulk sanitization so `branching_summary` and
# `commit_convention` are already safe (see bulk sanitization above).
# `scopes` and `hook_list` come straight from the profile so they're
# wrapped inline.
conv_rows=""
conv_rows+="| Commit format | ${commit_convention} |"$'\n'

# Merge profile scopes with workspace-derived extra scopes.
all_scopes='[]'
if jq -e '.conventions.commit_scopes' <<<"$profile_json" >/dev/null 2>&1; then
  all_scopes=$(jq -c '.conventions.commit_scopes // []' <<<"$profile_json")
fi
if [[ -n "$extra_scopes_path" && -f "$extra_scopes_path" ]]; then
  extra=$(jq -c '.' "$extra_scopes_path" 2>/dev/null || echo '[]')
  all_scopes=$(jq -c --argjson e "$extra" '. + $e | unique' <<<"$all_scopes")
fi
scopes_str=$(jq -r 'join(", ")' <<<"$all_scopes")
[[ -n "$scopes_str" ]] && conv_rows+="| Commit scopes | $(nyann::safe_md_cell "$scopes_str") |"$'\n'
conv_rows+="| Branching | ${branching_summary} |"$'\n'

hook_list=$(jq -r '[.hooks.pre_commit[], .hooks.commit_msg[]] | unique | join(", ")' <<<"$profile_json")
[[ -n "$hook_list" ]] && conv_rows+="| Hooks | $(nyann::safe_md_cell "$hook_list") |"$'\n'

# --- workspace section (conditional) -----------------------------------------

ws_section=""
if [[ -n "$ws_table_rows" ]]; then
  ws_section="
## Workspaces
| Path | Language | Framework | Key commands |
|---|---|---|---|
${ws_table_rows%$'\n'}
"
fi

# --- assemble nyann block ---------------------------------------------------

block="$(cat <<EOF
<!-- nyann:start -->
# ${project_name}

> Claude primer. Scan top-to-bottom; follow links for detail.

## Stack
| Thing | Value |
|---|---|
| Language | ${stack_language} |
| Framework | ${stack_framework} |
| Package manager | ${stack_pkgmgr} |
| Monorepo | ${stack_monorepo} |
${ws_section}
## How to work here
| Task | Command / convention |
|---|---|
| Install | \`${install_cmd}\` |
| Run | \`${run_cmd}\` |
| Test | \`${test_cmd}\` |
| Lint | \`${lint_cmd}\` |
| Branching | ${branching_summary} |
| Commits | ${commit_convention} — e.g. \`${commit_example}\` |

## Docs map
| What | Where |
|---|---|
${docs_rows%$'\n'}

## Memory
Session notes and persistent scratch live in [\`${mem_path}/\`](./${mem_path_target}/README.md). TODOs Claude should remember, open questions, mid-session decisions.

## Conventions
| Area | Rule |
|---|---|
${conv_rows%$'\n'}

## Nyann
Generated by [nyann](https://github.com/thettwe/nyann) on ${today} from profile \`${profile_name}\` (docs strategy: ${storage_strategy}). Run \`/nyann:doctor\` to audit hygiene.
<!-- nyann:end -->
EOF
)"

# --- merge with any existing CLAUDE.md --------------------------------------

claude_path="$target_root/CLAUDE.md"
soft_cap=3072
# Use the plugin-wide hard-cap constant from _lib.sh so the writer
# and the drift checker (bin/check-claude-md-size.sh) agree on the
# threshold. The two previously diverged (this script: fixed 8192;
# checker: budget_bytes*2), producing false "critical" doctor reports
# for files gen-claudemd had just accepted.
hard_cap="$NYANN_CLAUDEMD_HARD_CAP_BYTES"

# Enforce the size cap against the *final* file — the user-facing contract
# is "CLAUDE.md is ≤ 3 KB soft, 8 KB hard", not "the block we inject is".
# check_size takes a byte count and enforces the hard cap (with --force
# override) + warns on the soft cap.
check_size() {
  local total="$1" label="$2"
  if (( total > hard_cap )) && ! $force; then
    nyann::warn "${label} is ${total} B (> hard cap ${hard_cap} B). Pass --force to write anyway."
    exit 1
  elif (( total > soft_cap )); then
    nyann::warn "${label} is ${total} B (> soft cap ${soft_cap} B). Consider trimming or moving content into linked docs."
  fi
}

size_bytes=$(printf '%s\n' "$block" | wc -c | tr -d ' ')

if [[ -L "$claude_path" ]]; then
  nyann::die "refusing to write CLAUDE.md via symlink: $claude_path"
fi

if [[ ! -f "$claude_path" ]]; then
  check_size "$size_bytes" "CLAUDE.md"
  printf '%s\n' "$block" > "$claude_path"
  nyann::log "wrote $claude_path (${size_bytes} B)"
  exit 0
fi

existing="$(cat "$claude_path")"

if grep -Fq '<!-- nyann:start -->' "$claude_path" && grep -Fq '<!-- nyann:end -->' "$claude_path"; then
  # Verify marker order before letting the non-greedy .*? match run — a
  # file with `<!-- nyann:end -->` appearing before `<!-- nyann:start -->`
  # (merge-conflict damage, hand-edit mistake) would otherwise let the
  # regex span and destroy user content between a stray end and the next
  # start. Bail loudly instead of clobbering.
  start_line=$(grep -nF -m1 '<!-- nyann:start -->' "$claude_path" | cut -d: -f1)
  end_line=$(grep -nF -m1 '<!-- nyann:end -->'   "$claude_path" | cut -d: -f1)
  if [[ -z "$start_line" || -z "$end_line" ]] || (( start_line >= end_line )); then
    nyann::die "CLAUDE.md has nyann markers in the wrong order (start=${start_line:-missing}, end=${end_line:-missing}); refusing to replace — fix the file by hand"
  fi

  # Replace between markers; preserve everything outside the delimiters.
  # Install an EXIT trap *before* mutating $tmp. If perl or check_size
  # die (perl unavailable, size > hard cap, etc.) the `mv "$tmp" …` line
  # below never runs — without the trap, both $tmp and $block_file leak
  # into /tmp forever.
  tmp="$(mktemp -t nyann-claude.XXXXXX)"
  block_file="$(mktemp -t nyann-block.XXXXXX)"
  trap 'rm -f "$tmp" "$block_file"' EXIT
  cp "$claude_path" "$tmp"
  printf '%s\n' "$block" > "$block_file"
  NYANN_BLOCK_FILE="$block_file" perl -0777 -i -pe '
    BEGIN { open(my $f, "<", $ENV{NYANN_BLOCK_FILE}) or die $!; local $/; $block = <$f>; chomp $block; }
    s/<!-- nyann:start -->.*?<!-- nyann:end -->/$block/s;
  ' "$tmp"
  total_bytes=$(wc -c < "$tmp" | tr -d ' ')
  check_size "$total_bytes" "CLAUDE.md (merged)"
  mv "$tmp" "$claude_path"
  tmp=""
  rm -f "$block_file"
  block_file=""
  nyann::log "replaced nyann block in $claude_path (block ${size_bytes} B, file ${total_bytes} B)"
else
  # Also trap the append path so a failing check_size doesn't orphan $merged.
  merged=$(mktemp -t nyann-claude-merged.XXXXXX)
  trap 'rm -f "$merged"' EXIT
  {
    printf '%s\n' "$existing"
    printf '\n<!-- nyann: appended block — user content above preserved verbatim. -->\n'
    printf '%s\n' "$block"
  } > "$merged"
  total_bytes=$(wc -c < "$merged" | tr -d ' ')
  check_size "$total_bytes" "CLAUDE.md (appended)"
  mv "$merged" "$claude_path"
  merged=""
  nyann::log "appended nyann block to $claude_path (block ${size_bytes} B, file ${total_bytes} B)"
fi
