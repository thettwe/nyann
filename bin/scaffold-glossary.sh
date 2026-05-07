#!/usr/bin/env bash
# scaffold-glossary.sh — detect exported top-level types in a target repo
# and seed (or refresh) the auto block of docs/glossary.md.
#
# Usage:
#   scaffold-glossary.sh --target <repo>
#                        [--max-terms 50]
#                        [--languages auto|go,ts,python,...]
#                        [--force-merge]
#                        [--json]
#
# Detection is regex-based and conservative: top-level (column 1),
# exported (Go: capital first letter; TS/JS: `export`; Python: `class`
# at top level; Rust: `pub`; Java/Kotlin/Swift: `public`). False
# positives are bounded by the per-language predicates and the
# external-reference cap (we drop terms with zero external uses, which
# almost always means a private helper that the regex caught).
#
# Output: GlossaryDraft JSON on stdout when --json is set; otherwise
# the script also writes (or merges) docs/glossary.md and emits a
# short [nyann] log line.
#
# The auto block is delimited by:
#   <!-- nyann:glossary:auto-start -->
#   <!-- nyann:glossary:auto-end -->
# Content outside the markers is preserved verbatim. Re-running with
# --force-merge replaces only the auto block.
#
# When the file exists and lacks the markers (e.g. someone hand-wrote
# a glossary before opting in to auto-populate), the script refuses
# to mutate without --force-merge — there's no safe place to insert
# a regenerated block without risking a clobber.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
max_terms=50
languages_csv="auto"
force_merge=false
json_out=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        target="${2:-}"; shift 2 ;;
    --target=*)      target="${1#--target=}"; shift ;;
    --max-terms)     max_terms="${2:-50}"; shift 2 ;;
    --max-terms=*)   max_terms="${1#--max-terms=}"; shift ;;
    --languages)     languages_csv="${2:-auto}"; shift 2 ;;
    --languages=*)   languages_csv="${1#--languages=}"; shift ;;
    --force-merge)   force_merge=true; shift ;;
    --json)          json_out=true; shift ;;
    -h|--help)       sed -n '3,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
target="$(cd "$target" && pwd)"

# --- Resolve language set ----------------------------------------------------
# "auto" reads the StackDescriptor's primary + secondary languages
# (when one is reachable next to target/). Falls back to scanning every
# supported language so a fresh repo without detect-stack run still
# produces something useful.
resolve_languages() {
  local langs=()
  if [[ "$languages_csv" == "auto" ]]; then
    if nyann::has_cmd "${_script_dir}/detect-stack.sh"; then
      local stack_json
      stack_json=$("${_script_dir}/detect-stack.sh" --path "$target" 2>/dev/null || echo '{}')
      local pl sl
      pl=$(jq -r '.primary_language // "unknown"' <<<"$stack_json")
      sl=$(jq -r '.secondary_languages // [] | join(",")' <<<"$stack_json")
      for l in "$pl" $(tr ',' ' ' <<<"$sl"); do
        case "$l" in
          typescript|javascript) langs+=(ts) ;;
          go)                    langs+=(go) ;;
          python)                langs+=(python) ;;
          rust)                  langs+=(rust) ;;
          java)                  langs+=(java) ;;
          kotlin)                langs+=(kotlin) ;;
          swift)                 langs+=(swift) ;;
        esac
      done
    fi
    # Fallback: scan everything we know how to parse.
    if [[ ${#langs[@]} -eq 0 ]]; then
      langs=(go ts python rust java kotlin swift)
    fi
  else
    local IFS=','
    # shellcheck disable=SC2206
    local arr=($languages_csv)
    for l in "${arr[@]}"; do
      case "$l" in
        go|ts|js|python|rust|java|kotlin|swift) langs+=("$l") ;;
        *) nyann::die "unknown language: $l (want any of: go ts js python rust java kotlin swift auto)" ;;
      esac
    done
  fi
  # Dedupe (bash 3.2 — no associative arrays).
  printf '%s\n' "${langs[@]}" | awk '!seen[$0]++'
}

# bash 3.2 (default macOS) lacks `mapfile`; fall back to a read-loop.
LANGS=()
while IFS= read -r _l; do
  [[ -n "$_l" ]] && LANGS+=("$_l")
done < <(resolve_languages)

# --- File enumeration --------------------------------------------------------
# Use `git ls-files` when available so untracked artefacts don't inflate
# the candidate set. Fall back to `find` for non-git fixtures.
list_files() {
  local lang="$1"
  local globs=()
  case "$lang" in
    go)     globs=('*.go') ;;
    ts)     globs=('*.ts' '*.tsx') ;;
    js)     globs=('*.js' '*.jsx' '*.mjs' '*.cjs') ;;
    python) globs=('*.py') ;;
    rust)   globs=('*.rs') ;;
    java)   globs=('*.java') ;;
    kotlin) globs=('*.kt' '*.kts') ;;
    swift)  globs=('*.swift') ;;
  esac
  local g
  if (cd "$target" && git rev-parse --git-dir >/dev/null 2>&1); then
    for g in "${globs[@]}"; do
      ( cd "$target" && git ls-files "$g" 2>/dev/null )
    done
  else
    for g in "${globs[@]}"; do
      ( cd "$target" && find . -type f -name "$g" 2>/dev/null | sed 's#^\./##' )
    done
  fi
}

# Per-language detector. Emits TSV rows: name TAB kind TAB defined_in.
# The regex is permissive enough to catch standard idiomatic decls and
# strict enough to reject inline / generic comments.
detect_language() {
  local lang="$1"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$target/$f" ]] || continue
    case "$lang" in
      go)
        # Top-level: `type X struct {` / `type X interface {`. Exported
        # iff first letter is upper-case.
        awk '
          /^type[[:space:]]+[A-Z][A-Za-z0-9_]*[[:space:]]+struct[[:space:]]*\{/ {
            split($0, a, /[[:space:]]+/); print a[2] "\tstruct"
          }
          /^type[[:space:]]+[A-Z][A-Za-z0-9_]*[[:space:]]+interface[[:space:]]*\{/ {
            split($0, a, /[[:space:]]+/); print a[2] "\tinterface"
          }
        ' "$target/$f" | awk -v file="$f" -F'\t' '{ print $1 "\t" $2 "\t" file }'
        ;;
      ts|js)
        awk '
          /^export[[:space:]]+interface[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/ {
            sub(/^export[[:space:]]+interface[[:space:]]+/, "")
            sub(/[[:space:]<{].*$/, "")
            print $0 "\tinterface"
          }
          /^export[[:space:]]+type[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/ {
            sub(/^export[[:space:]]+type[[:space:]]+/, "")
            sub(/[[:space:]<=].*$/, "")
            print $0 "\ttype"
          }
          /^export[[:space:]]+(abstract[[:space:]]+)?class[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/ {
            sub(/^export[[:space:]]+(abstract[[:space:]]+)?class[[:space:]]+/, "")
            sub(/[[:space:]<{].*$/, "")
            print $0 "\tclass"
          }
          /^export[[:space:]]+enum[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/ {
            sub(/^export[[:space:]]+enum[[:space:]]+/, "")
            sub(/[[:space:]{].*$/, "")
            print $0 "\tenum"
          }
        ' "$target/$f" | awk -v file="$f" -F'\t' '{ print $1 "\t" $2 "\t" file }'
        ;;
      python)
        awk '
          /^class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            sub(/^class[[:space:]]+/, "")
            sub(/[[:space:](:].*$/, "")
            print $0 "\tclass"
          }
        ' "$target/$f" | awk -v file="$f" -F'\t' '{ print $1 "\t" $2 "\t" file }'
        ;;
      rust)
        awk '
          /^pub[[:space:]]+struct[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            sub(/^pub[[:space:]]+struct[[:space:]]+/, "")
            sub(/[[:space:]<({;].*$/, "")
            print $0 "\tstruct"
          }
          /^pub[[:space:]]+trait[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            sub(/^pub[[:space:]]+trait[[:space:]]+/, "")
            sub(/[[:space:]<{:].*$/, "")
            print $0 "\ttrait"
          }
          /^pub[[:space:]]+enum[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            sub(/^pub[[:space:]]+enum[[:space:]]+/, "")
            sub(/[[:space:]<{:].*$/, "")
            print $0 "\tenum"
          }
        ' "$target/$f" | awk -v file="$f" -F'\t' '{ print $1 "\t" $2 "\t" file }'
        ;;
      java|kotlin)
        awk '
          /^[[:space:]]*public[[:space:]]+(abstract[[:space:]]+|final[[:space:]]+|sealed[[:space:]]+|open[[:space:]]+)?(class|interface|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            line = $0
            sub(/^[[:space:]]*public[[:space:]]+/, "", line)
            sub(/^(abstract|final|sealed|open)[[:space:]]+/, "", line)
            kind = line
            sub(/[[:space:]].*$/, "", kind)
            sub(/^(class|interface|enum)[[:space:]]+/, "", line)
            sub(/[[:space:]<({:].*$/, "", line)
            print line "\t" kind
          }
        ' "$target/$f" | awk -v file="$f" -F'\t' '{ print $1 "\t" $2 "\t" file }'
        ;;
      swift)
        awk '
          /^public[[:space:]]+(struct|class|protocol|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
            line = $0
            sub(/^public[[:space:]]+/, "", line)
            kind = line
            sub(/[[:space:]].*$/, "", kind)
            sub(/^(struct|class|protocol|enum)[[:space:]]+/, "", line)
            sub(/[[:space:]<({:].*$/, "", line)
            # Swift `class` is a kind we track too; keep class label.
            print line "\t" kind
          }
        ' "$target/$f" | awk -v file="$f" -F'\t' '{ print $1 "\t" $2 "\t" file }'
        ;;
    esac
  done < <(list_files "$lang")
}

# --- Detect terms across all selected languages ------------------------------

candidates_tsv=$(mktemp -t nyann-glossary-cand.XXXXXX)
trap 'rm -f "$candidates_tsv"' EXIT

scanned_files=0
for lang in "${LANGS[@]}"; do
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    scanned_files=$((scanned_files + 1))
  done < <(list_files "$lang")
  detect_language "$lang" | awk -v lang="$lang" -F'\t' '{ print $1 "\t" lang "\t" $2 "\t" $3 }' \
    >> "$candidates_tsv"
done

# Dedupe by (name, language) keeping the first definition file.
deduped_tsv=$(mktemp -t nyann-glossary-dedup.XXXXXX)
awk -F'\t' '
  { key = $1 "\t" $2 }
  !seen[key]++ { print }
' "$candidates_tsv" > "$deduped_tsv"

total_candidates=$(wc -l < "$deduped_tsv" | tr -d ' ')

# --- Reference count: count appearances OUTSIDE the defining file -----------
# Use `git grep -F` (literal) to count word-boundary occurrences. This
# is approximate — a comment containing the term inflates the count —
# but it's good enough to rank by, which is the only consumer.

ranked_tsv=$(mktemp -t nyann-glossary-rank.XXXXXX)
trap 'rm -f "$candidates_tsv" "$deduped_tsv" "$ranked_tsv"' EXIT

while IFS=$'\t' read -r name lang kind defined_in; do
  [[ -z "$name" ]] && continue
  # Cap the reference count at 9999 to avoid pathological scans.
  refs=0
  if (cd "$target" && git rev-parse --git-dir >/dev/null 2>&1); then
    refs=$(cd "$target" && \
      git grep -wcF -- "$name" 2>/dev/null \
      | grep -v "^$defined_in:" \
      | awk -F: '{ s += $2 } END { print s+0 }')
  else
    refs=$(grep -rwF -- "$name" "$target" 2>/dev/null \
      | grep -cv "/${defined_in}:")
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$refs" "$name" "$lang" "$kind" "$defined_in" >> "$ranked_tsv"
done < "$deduped_tsv"

# --- Sort by reference count desc, drop zero-ref entries, cap to max --------
selected_tsv=$(mktemp -t nyann-glossary-sel.XXXXXX)
trap 'rm -f "$candidates_tsv" "$deduped_tsv" "$ranked_tsv" "$selected_tsv"' EXIT

# Sort numeric desc on column 1; tiebreak alphabetical asc on column 2.
sort -t$'\t' -k1,1nr -k2,2 "$ranked_tsv" \
  | awk -F'\t' -v cap="$max_terms" 'NR <= cap && $1 > 0 { print }' \
  > "$selected_tsv"

selected=$(wc -l < "$selected_tsv" | tr -d ' ')

# --- Build the GlossaryDraft JSON --------------------------------------------

terms_json='[]'
while IFS=$'\t' read -r refs name lang kind defined_in; do
  [[ -z "$name" ]] && continue
  # Used-in head: top 5 referrer files. Approximation: `git grep -lwF`
  # excluding the defining file.
  used_in_json='[]'
  if (cd "$target" && git rev-parse --git-dir >/dev/null 2>&1); then
    used_in_json=$(cd "$target" && \
      git grep -lwF -- "$name" 2>/dev/null \
      | awk -v def="$defined_in" '$0 != def' \
      | head -n 5 \
      | jq -R . | jq -s .)
  fi
  terms_json=$(jq \
    --arg name "$name" \
    --arg lang "$lang" \
    --arg kind "$kind" \
    --arg defined "$defined_in" \
    --argjson used "$used_in_json" \
    --argjson refs "$refs" \
    '. + [{ name: $name, language: $lang, kind: $kind, defined_in: $defined, used_in: $used, reference_count: $refs }]' \
    <<<"$terms_json")
done < "$selected_tsv"

draft_json=$(jq -n \
  --arg target "$target" \
  --argjson scanned "$scanned_files" \
  --argjson total "$total_candidates" \
  --argjson sel "$selected" \
  --argjson langs "$(printf '%s\n' "${LANGS[@]}" | jq -R . | jq -s .)" \
  --argjson terms "$terms_json" \
  '{
    target: $target,
    scanned_files: $scanned,
    total_candidates: $total,
    selected: $sel,
    languages: $langs,
    terms: $terms
  }')

# --- Write or update docs/glossary.md ----------------------------------------

START_MARKER='<!-- nyann:glossary:auto-start -->'
END_MARKER='<!-- nyann:glossary:auto-end -->'

# Render the auto block content from the draft. One H3 per term,
# definition-stub + signature + defined_in. Empty fields ("") get
# elided rather than producing dangling labels.
render_auto_block() {
  local d="$1"
  printf '%s\n' "$START_MARKER"
  # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
  printf '<!-- This block is regenerated by `bin/scaffold-glossary.sh`. Edit content OUTSIDE the markers to keep your changes. -->\n'
  printf '\n'
  printf '<!-- %s detected term(s) — %s scanned file(s); %s total candidates. -->\n\n' \
    "$(jq -r '.selected' <<<"$d")" \
    "$(jq -r '.scanned_files' <<<"$d")" \
    "$(jq -r '.total_candidates' <<<"$d")"
  jq -r '
    .terms[]
    | "### " + .name + "\n\n"
      + "**Type.** " + .language + " " + .kind + ".\n\n"
      + "**Defined in.** `" + .defined_in + "`.\n\n"
      + (if (.used_in | length) > 0
         then "**Used in.** " + ([.used_in[] | "`" + . + "`"] | join(", ")) + ".\n\n"
         else "" end)
      + "**Definition.** _(write a one-sentence definition)_\n\n"
      + "---\n"
  ' <<<"$d"
  printf '%s\n' "$END_MARKER"
}

glossary_path="$target/docs/glossary.md"

# Idempotent + safe write semantics:
#   - file missing → create from the template, then inject the auto block
#   - file exists with markers → replace content between markers
#   - file exists without markers → require --force-merge OR inject after
#     "## Terms" heading; if neither marker NOR heading found, refuse
write_glossary() {
  if [[ ! -f "$glossary_path" ]]; then
    mkdir -p "$(dirname "$glossary_path")"
    # Seed from the template, then perl-splice the auto block. The
    # template ships with markers in place, so the seed already gives
    # us a place to land.
    if [[ -f "${_script_dir}/../templates/docs/glossary.tmpl" ]]; then
      cp "${_script_dir}/../templates/docs/glossary.tmpl" "$glossary_path"
    else
      printf '# Glossary\n\n## Terms\n\n%s\n%s\n' "$START_MARKER" "$END_MARKER" > "$glossary_path"
    fi
  fi

  if grep -Fq "$START_MARKER" "$glossary_path" && grep -Fq "$END_MARKER" "$glossary_path"; then
    # Splice between markers.
    block_file=$(mktemp -t nyann-glossary-block.XXXXXX)
    render_auto_block "$draft_json" > "$block_file"
    tmp=$(mktemp -t nyann-glossary-merged.XXXXXX)
    NYANN_GLOSSARY_BLOCK="$block_file" perl -0777 -i -pe '
      BEGIN { open(my $f, "<", $ENV{NYANN_GLOSSARY_BLOCK}) or die $!; local $/; $b = <$f>; chomp $b; }
      s/<!-- nyann:glossary:auto-start -->.*?<!-- nyann:glossary:auto-end -->/$b/s;
    ' "$glossary_path"
    rm -f "$tmp" "$block_file"
    nyann::log "scaffold-glossary: regenerated auto block in $glossary_path ($(jq -r '.selected' <<<"$draft_json") terms)"
    return 0
  fi

  if ! $force_merge; then
    nyann::warn "$glossary_path exists without nyann markers; pass --force-merge to inject the auto block"
    return 0
  fi

  # Append the auto block to the bottom — safe fallback for users who
  # opted in but had a hand-written glossary.
  {
    printf '\n'
    render_auto_block "$draft_json"
    printf '\n'
  } >> "$glossary_path"
  nyann::log "scaffold-glossary: appended auto block to $glossary_path ($(jq -r '.selected' <<<"$draft_json") terms)"
}

if ! $json_out; then
  write_glossary
fi

if $json_out; then
  printf '%s\n' "$draft_json"
fi
