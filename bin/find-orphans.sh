#!/usr/bin/env bash
# find-orphans.sh — locate docs/ + memory/ files with zero inbound references.
#
# Usage: find-orphans.sh --target <repo>
#
# An orphan is a file under docs/ or memory/ whose basename (or repo-relative
# path) appears in no other doc or CLAUDE.md. Excluded by default:
#   - patterns from templates/orphan-exclusions.txt
#   - patterns from the repo's own .nyann-ignore (basename glob)
#
# Output: JSON OrphanReport on stdout
#         (schemas/orphan-report.schema.json).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
exclusions_path="${_script_dir}/../templates/orphan-exclusions.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --exclusions)      exclusions_path="${2:-}"; shift 2 ;;
    --exclusions=*)    exclusions_path="${1#--exclusions=}"; shift ;;
    -h|--help)         sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
target="$(cd "$target" && pwd)"

# --- load exclusion globs ----------------------------------------------------

# shellcheck disable=SC2034  # populated by nyann::load_globs, read by nyann::is_excluded
exclusions=()
nyann::load_globs "$exclusions_path"
nyann::load_globs "$target/.nyann-ignore"

# --- enumerate scan roots + everybody who might reference them --------------

scan_dirs=()
[[ -d "$target/docs" ]]   && scan_dirs+=("$target/docs")
[[ -d "$target/memory" ]] && scan_dirs+=("$target/memory")

if [[ ${#scan_dirs[@]} -eq 0 ]]; then
  jq -n '{scanned: 0, orphans: []}'
  exit 0
fi

# Reference corpus = CLAUDE.md + every *.md / *.markdown under scan_dirs.
corpus=()
[[ -f "$target/CLAUDE.md" ]] && corpus+=("$target/CLAUDE.md")
while IFS= read -r -d '' f; do
  corpus+=("$f")
done < <(find "${scan_dirs[@]}" -type f \( -name '*.md' -o -name '*.markdown' \) -print0)

# --- for each file, check if any other file references it -------------------

# Build the reference corpus as a single concatenated buffer with
# per-file boundary markers. The single-buffer + one-awk-pass-per-
# candidate shape keeps total open/close overhead at O(N) instead of
# the O(N²·T) that per-file grep loops produce on large doc trees.
#
# Each corpus section starts with `<MARKER><abs-path>\n` so awk can
# tell which file a match landed in (used to skip self-references).
# Per-run marker — a doc legitimately containing `__NYANN_CORPUS_FILE__:`
# (e.g. nyann's own internal docs about find-orphans) would otherwise be
# misread as a corpus boundary. Suffix with $$ + a random tag so colliding
# content is essentially impossible.
CORPUS_MARKER="__NYANN_CORPUS_FILE_${$}_${RANDOM}__:"
# Install the cleanup trap up-front against placeholder vars and let
# ${var:+} guard pick up whichever tmpfiles have already been allocated.
# Without this, a SIGINT during the corpus-build loop below (which can
# take a non-trivial fraction of a second on large doc trees) would
# leak corpus_buf into $TMPDIR.
corpus_buf=""
orphans_tsv=""
trap 'rm -f ${corpus_buf:+"$corpus_buf"} ${orphans_tsv:+"$orphans_tsv"}' EXIT
corpus_buf=$(mktemp -t nyann-corpus.XXXXXX)
for ref in "${corpus[@]}"; do
  printf '\n%s%s\n' "$CORPUS_MARKER" "$ref" >> "$corpus_buf"
  cat "$ref" >> "$corpus_buf" 2>/dev/null || true
done

scanned=0
# Accumulate orphans as TSV; collapses N per-orphan jq forks into 1 at end.
orphans_tsv=$(mktemp -t nyann-orphans.XXXXXX)
# US (0x1F) is illegal in filenames, so it makes a safe term separator
# inside `awk -v`. This drops the per-iteration mktemp + grep -Fxq
# pipeline (3 forks per candidate) — awk now signals "found" via its
# END exit code.
US=$'\037'
now=$(date +%s)

while IFS= read -r -d '' f; do
  rel="${f#"$target"/}"
  base="$(basename "$f")"

  # Skip excluded.
  if nyann::is_excluded "$base" "$rel"; then
    continue
  fi

  scanned=$((scanned + 1))

  # Consider directories with README inside — the README is the directory's
  # entry point; don't flag it as orphan if the directory is referenced
  # elsewhere.
  terms_str="$base"
  if [[ "$base" == "README.md" ]]; then
    # Dir-level reference (e.g. "docs/research/README.md" or "docs/research/").
    dir="$(dirname "$rel")"
    terms_str+="${US}${dir}${US}$(basename "$dir")"
  fi
  # Also consider the relative-path form (e.g. `docs/architecture.md`).
  terms_str+="${US}${rel}"

  # Single awk pass over the concatenated corpus: track which corpus
  # file each line belongs to and report a hit only when a search term
  # matches in a file OTHER than the candidate itself. Exits on first
  # qualifying match for early termination on huge corpora; END's exit
  # code propagates to bash so we don't need a stdout-grep pipeline.
  if awk \
       -v marker="$CORPUS_MARKER" \
       -v self="$f" \
       -v terms_str="$terms_str" \
       -v sep="$US" \
       '
       BEGIN {
         n = split(terms_str, terms, sep)
         marker_len = length(marker)
         is_self = 0
         found = 0
       }
       substr($0, 1, marker_len) == marker {
         current = substr($0, marker_len + 1)
         is_self = (current == self)
         next
       }
       !is_self {
         for (i = 1; i <= n; i++) {
           if (terms[i] != "" && index($0, terms[i]) > 0) { found = 1; exit }
         }
       }
       END { exit (found ? 0 : 1) }
       ' "$corpus_buf"; then
    : # referenced — not an orphan
  else
    # Compute age in days.
    if stat -f "%m" "$f" >/dev/null 2>&1; then
      mtime=$(stat -f "%m" "$f")
    else
      mtime=$(stat -c "%Y" "$f")
    fi
    days=$(( (now - mtime) / 86400 ))
    # Unix filenames may legally contain tab/CR/LF. Without sanitising,
    # one such filename would split the TSV row across columns or lines
    # and the trailing `jq | tonumber` reduce would abort the entire
    # audit (no orphan report at all) instead of just dropping that row.
    rel_safe="${rel//[$'\t\r\n']/ }"
    printf '%s\t%s\n' "$rel_safe" "$days" >> "$orphans_tsv"
  fi
done < <(find "${scan_dirs[@]}" -type f -print0)

orphans=$(jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({path:.[0], last_modified_days_ago:(.[1]|tonumber)})' < "$orphans_tsv")

jq -n \
  --argjson scanned "$scanned" \
  --argjson orphans "$orphans" \
  '{ scanned: $scanned, orphans: $orphans }'
