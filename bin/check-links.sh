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

# Extract links of the form [text](url) per line. Skip angle-bracket / reference
# style for now; the common case is inline links.
extract_links_py() {
  python3 - "$1" <<'PY'
import re, sys
pattern = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
with open(sys.argv[1]) as f:
    text = f.read()
for m in pattern.findall(text):
    print(m)
PY
}

# bash 3.2 + set -u treats "${sources[@]}" on an empty array as unbound.
if [[ ${#sources[@]} -gt 0 ]]; then
for src in "${sources[@]}"; do
  full="$target/$src"
  [[ -f "$full" ]] || continue
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    checked=$((checked + 1))

    case "$link" in
      '#'*)
        skipped=$(jq --arg src "$src" --arg link "$link" \
          '. + [{ source: $src, link: $link, reason: "internal-anchor-check-disabled" }]' <<<"$skipped")
        ;;
      http://*|https://*)
        skipped=$(jq --arg src "$src" --arg link "$link" \
          '. + [{ source: $src, link: $link, reason: "external-web-check-disabled" }]' <<<"$skipped")
        ;;
      mailto:*|data:*|tel:*)
        skipped=$(jq --arg src "$src" --arg link "$link" \
          '. + [{ source: $src, link: $link, reason: "uncheckable-scheme" }]' <<<"$skipped")
        ;;
      obsidian://*)
        mcp=$(jq --arg src "$src" --arg link "$link" \
          '. + [{ source: $src, link: $link, connector: "obsidian" }]' <<<"$mcp")
        ;;
      notion://*)
        mcp=$(jq --arg src "$src" --arg link "$link" \
          '. + [{ source: $src, link: $link, connector: "notion" }]' <<<"$mcp")
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
        # Canonicalise (`..` collapse, trailing-slash trim) AND verify
        # the resolved path is still inside $target. Without this, a
        # link like `../../outside.md` from deep in docs/ could hit an
        # existing file outside the repo and be reported as not-broken.
        # Uses python so this works on macOS (no `realpath --relative-to`).
        resolved=$(TARGET="$target" CAND="$candidate" python3 -c '
import os, sys
target = os.path.realpath(os.environ["TARGET"])
cand = os.path.realpath(os.environ["CAND"])
# Must be equal to target or a descendant of it.
if cand == target or cand.startswith(target + os.sep):
    print(cand)
else:
    print("")  # escapes the repo root
' 2>/dev/null)

        if [[ -z "$resolved" ]]; then
          broken=$(jq --arg src "$src" --arg link "$link" \
            '. + [{ source: $src, link: $link, reason: "escapes-repo-root" }]' <<<"$broken")
        elif [[ -e "$resolved" ]]; then
          :
        else
          broken=$(jq --arg src "$src" --arg link "$link" \
            '. + [{ source: $src, link: $link, reason: "file-not-found" }]' <<<"$broken")
        fi
        ;;
    esac
  done < <(extract_links_py "$full")
done
fi

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
