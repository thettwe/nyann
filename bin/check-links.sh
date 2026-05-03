#!/usr/bin/env bash
# check-links.sh — audit CLAUDE.md + docs/ + memory/ for broken markdown links.
#
# Usage: check-links.sh --target <repo>
#
# Output: JSON LinkCheckReport on stdout
#         (schemas/link-check-report.schema.json).
#
# Classification:
#   - `./foo.md`, `../bar.md`, relative/path/file.md → internal-file; stat.
#   - `#anchor`                                      → skipped (not yet supported).
#   - `http://`, `https://`                          → skipped: external-web-check-disabled.
#   - `obsidian://...`, `notion://...`               → needs_mcp_verify.
#   - `mailto:`, `data:`                             → skipped: uncheckable.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2:-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    -h|--help)  sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
target="$(cd "$target" && pwd)"

# --- collect files to scan ---------------------------------------------------

sources=()
[[ -f "$target/CLAUDE.md" ]] && sources+=("CLAUDE.md")
if [[ -d "$target/docs" ]]; then
  while IFS= read -r -d '' f; do
    sources+=("${f#"$target"/}")
  done < <(find "$target/docs" -type f \( -name '*.md' -o -name '*.markdown' \) -print0)
fi
if [[ -d "$target/memory" ]]; then
  while IFS= read -r -d '' f; do
    sources+=("${f#"$target"/}")
  done < <(find "$target/memory" -type f \( -name '*.md' -o -name '*.markdown' \) -print0)
fi

# --- scan each file ----------------------------------------------------------

broken='[]'
mcp='[]'
skipped='[]'
checked=0

# Degrade gracefully when python3 is absent. Emit an empty but
# structurally-valid LinkCheckReport with a `skipped[]` entry so the
# doctor aggregator can surface it.
if ! nyann::has_cmd python3; then
  jq -n '{
    checked: 0,
    broken: [],
    needs_mcp_verify: [],
    skipped: [{
      source: "check-links.sh",
      link: "",
      reason: "python3-missing"
    }]
  }'
  exit 0
fi

# Output accumulators are TSV tmp files, converted to JSON in a single
# trailing jq pass. The previous implementation forked jq per link
# (`. + [{...}]`) which on a doc-heavy repo with ~200 links cost ~200 jq
# invocations; this pass costs three. `path_under_target` from _lib.sh
# replaces the per-link `python3 -c` realpath canonicalisation, eliminating
# another ~150 python3 forks on the same workload.
broken_tsv=$(mktemp -t nyann-cl-broken.XXXXXX)
skipped_tsv=$(mktemp -t nyann-cl-skipped.XXXXXX)
mcp_tsv=$(mktemp -t nyann-cl-mcp.XXXXXX)
sources_tsv=""
trap 'rm -f "$broken_tsv" "$skipped_tsv" "$mcp_tsv" ${sources_tsv:+"$sources_tsv"}' EXIT

# Single python3 process extracts links from every source file.
# Input file: alternating <src>\0<full_path>\0<src>\0<full_path>... NUL
# records (Unix paths can contain tabs and newlines, so the previous
# TSV-per-line shape silently mis-attributed or skipped entries with
# such filenames). Output stays TSV — link hrefs are markdown-spec'd
# to exclude tab/newline so they're safe.
# Output: one `<src>\t<link>` per line on stdout.
# This collapses N python3 startups into 1.
links_raw=""
if [[ ${#sources[@]} -gt 0 ]]; then
  sources_tsv=$(mktemp -t nyann-cl-sources.XXXXXX)
  for src in "${sources[@]}"; do
    full="$target/$src"
    [[ -f "$full" ]] || continue
    printf '%s\0%s\0' "$src" "$full" >> "$sources_tsv"
  done
  if [[ -s "$sources_tsv" ]]; then
    # Pass the records file as argv[1] rather than via stdin redirection;
    # heredoc + < competes for fd 0 (shellcheck SC2261).
    links_raw=$(python3 - "$sources_tsv" <<'PY'
import re, sys
pattern = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
records_path = sys.argv[1]
with open(records_path, 'rb') as recfh:
    blob = recfh.read()
parts = blob.split(b'\0')
# Trailing empty element from the final NUL terminator; alternating pairs.
if parts and parts[-1] == b'':
    parts.pop()
for i in range(0, len(parts) - 1, 2):
    src = parts[i].decode('utf-8', errors='replace')
    full = parts[i + 1].decode('utf-8', errors='replace')
    try:
        with open(full) as f:
            text = f.read()
    except OSError:
        continue
    for m in pattern.findall(text):
        # Tabs in href are not legal markdown link targets; skip if any
        # leak through to keep the TSV contract clean.
        if '\t' in m or '\n' in m:
            continue
        # Output src\tlink. Source paths may contain tabs/newlines, so
        # sanitise to space here to keep the downstream `IFS=$'\t' read`
        # parseable. The original source file path is preserved in the
        # broken/skipped/mcp accumulators only via this `src` value, so
        # this is a one-time normalisation at the boundary.
        src_safe = src.replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')
        sys.stdout.write(f"{src_safe}\t{m}\n")
PY
)
  fi
fi

if [[ -n "$links_raw" ]]; then
  while IFS=$'\t' read -r src link; do
    [[ -z "$link" ]] && continue
    checked=$((checked + 1))

    case "$link" in
      '#'*)
        printf '%s\t%s\t%s\n' "$src" "$link" "internal-anchor-check-disabled" >> "$skipped_tsv"
        ;;
      http://*|https://*)
        printf '%s\t%s\t%s\n' "$src" "$link" "external-web-check-disabled" >> "$skipped_tsv"
        ;;
      mailto:*|data:*|tel:*)
        printf '%s\t%s\t%s\n' "$src" "$link" "uncheckable-scheme" >> "$skipped_tsv"
        ;;
      obsidian://*)
        printf '%s\t%s\t%s\n' "$src" "$link" "obsidian" >> "$mcp_tsv"
        ;;
      notion://*)
        printf '%s\t%s\t%s\n' "$src" "$link" "notion" >> "$mcp_tsv"
        ;;
      *)
        # Internal file. Strip any ?query or #anchor suffix before statting.
        path="${link%%#*}"
        path="${path%%\?*}"
        # Resolve relative to source file's directory.
        src_dir="$(dirname "$src")"
        if [[ "$src_dir" == "." ]]; then
          candidate="$target/$path"
        else
          candidate="$target/$src_dir/$path"
        fi
        # path_under_target is bash-native (cd + pwd -P + lexical ..
        # normalisation). It returns 0 + canonical path under $target,
        # or 1 if the candidate escapes. No python3 fork per link.
        if resolved=$(nyann::path_under_target "$target" "$candidate" 2>/dev/null); then
          if [[ ! -e "$resolved" ]]; then
            printf '%s\t%s\t%s\n' "$src" "$link" "file-not-found" >> "$broken_tsv"
          fi
        else
          printf '%s\t%s\t%s\n' "$src" "$link" "escapes-repo-root" >> "$broken_tsv"
        fi
        ;;
    esac
  done <<<"$links_raw"
fi

# Single jq per category turns TSV into JSON arrays. select(. != "") drops
# the empty trailing line that split("\n") leaves behind on a non-empty file.
broken=$(jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({source:.[0], link:.[1], reason:.[2]})' < "$broken_tsv")
skipped=$(jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({source:.[0], link:.[1], reason:.[2]})' < "$skipped_tsv")
mcp=$(jq -R -s '
  split("\n")
  | map(select(. != "") | split("\t"))
  | map({source:.[0], link:.[1], connector:.[2]})' < "$mcp_tsv")

jq -n \
  --argjson checked "$checked" \
  --argjson broken "$broken" \
  --argjson mcp "$mcp" \
  --argjson skipped "$skipped" \
  '{
    checked: $checked,
    broken: $broken,
    needs_mcp_verify: $mcp,
    skipped: $skipped
  }'
