#!/usr/bin/env bash
# optimize-claudemd.sh — optimize CLAUDE.md based on usage analysis.
#
# Usage:
#   optimize-claudemd.sh --target <repo> --profile <path>
#                        [--dry-run] [--force]
#
# Reads analysis from analyze-claudemd-usage.sh, applies recommendations
# within the nyann-managed block only. Preserves user content outside markers.
# Stays within 3KB soft budget; hard cap 8KB.
#
# Output: JSON result with applied changes and byte savings.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
profile_path=""
dry_run=false
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)       target="${2:-}"; shift 2 ;;
    --target=*)     target="${1#--target=}"; shift ;;
    --profile)      profile_path="${2:-}"; shift 2 ;;
    --profile=*)    profile_path="${1#--profile=}"; shift ;;
    --dry-run)      dry_run=true; shift ;;
    --force)        force=true; shift ;;
    -h|--help)      sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
[[ -n "$profile_path" && -f "$profile_path" ]] || nyann::die "--profile <path> is required"
target="$(cd "$target" && pwd)"

claudemd="$target/CLAUDE.md"
[[ -f "$claudemd" ]] || nyann::die "no CLAUDE.md found at $claudemd"

opt_tmp=""

MARKER_START="<!-- nyann:start -->"
MARKER_END="<!-- nyann:end -->"

if ! grep -qF "$MARKER_START" "$claudemd"; then
  nyann::die "CLAUDE.md has no nyann markers — run bootstrap first"
fi

# Run analysis. Forward --force only when the user explicitly passed
# it. The previous `${force:+--force}` form expanded whenever $force
# was non-empty — and `force=false` is non-empty, so --force was
# being forwarded on every invocation, silently bypassing the
# minimum-session guard inside analyze-claudemd-usage.sh.
analyze_args=(--target "$target")
if [[ "$force" == "true" ]]; then
  analyze_args+=(--force)
fi
analysis=$("${_script_dir}/analyze-claudemd-usage.sh" "${analyze_args[@]}")

sufficient=$(jq -r '.sufficient_data' <<<"$analysis")
if [[ "$sufficient" != "true" ]]; then
  nyann::log "insufficient usage data — need more sessions before optimization"
  printf '%s\n' "$analysis"
  exit 0
fi

recommendations=$(jq -c '.recommendations' <<<"$analysis")
rec_count=$(jq 'length' <<<"$recommendations")

if [[ "$rec_count" -eq 0 ]]; then
  nyann::log "no optimization recommendations — CLAUDE.md looks good"
  jq -n '{ applied: [], bytes_before: 0, bytes_after: 0, savings: 0 }'
  exit 0
fi

# Read current CLAUDE.md
bytes_before=$(wc -c < "$claudemd" | tr -d ' ')

# Extract the nyann block
nyann_block=$(sed -n "/${MARKER_START}/,/${MARKER_END}/p" "$claudemd")
modified_block="$nyann_block"

applied='[]'

# Apply recommendations
for i in $(seq 0 $((rec_count - 1))); do
  rec=$(jq -c ".[$i]" <<<"$recommendations")
  action=$(jq -r '.action' <<<"$rec")
  section=$(jq -r '.section // empty' <<<"$rec")
  content=$(jq -r '.content // empty' <<<"$rec")
  reason=$(jq -r '.reason // empty' <<<"$rec")

  case "$action" in
    remove)
      if [[ -n "$section" ]]; then
        # Remove the section from the block (header + body until next ## or marker).
        # Use `env` so the variables actually reach awk's environment. The
        # earlier `VAR=val \ modified_block=$(awk ...)` form silently
        # dropped them — bash treats a chain that ends in another
        # assignment as shell-local, never exporting to the subshell —
        # so awk saw `sec=""` and skipped lines indiscriminately.
        # Single-quotes around the awk script are intentional — that's
        # how you embed an awk program in shell. ENVIRON pulls the
        # variables in from the surrounding `env` prefix.
        # shellcheck disable=SC2016
        modified_block=$(env \
          NYANN_AWK_SEC="## $section" \
          NYANN_AWK_ME="$MARKER_END" \
          awk '
            BEGIN { sec=ENVIRON["NYANN_AWK_SEC"]; me=ENVIRON["NYANN_AWK_ME"] }
            $0 == sec { skip=1; next }
            skip && /^## / { skip=0 }
            skip && $0 == me { skip=0 }
            !skip { print }
          ' <<<"$modified_block")
        applied=$(jq --arg a "remove" --arg s "$section" --arg r "$reason" \
          '. + [{ action: $a, section: $s, reason: $r }]' <<<"$applied")
      fi
      ;;
    compress)
      # Mark section for compression (skill layer handles actual rewrite)
      applied=$(jq --arg a "compress" --arg s "$section" --arg r "$reason" \
        '. + [{ action: $a, section: $s, reason: $r }]' <<<"$applied")
      ;;
    add)
      if [[ -n "$content" ]]; then
        # Pick the insertion target. nyann-generated CLAUDE.md uses
        # `## How to work here` (see bin/gen-claudemd.sh); older
        # hand-written files often use `## Build` or `## Build commands`.
        # Prefer the generated heading when present so the insertion
        # actually lands on real nyann-managed files; fall back to the
        # legacy heading for hand-written ones.
        target_header=""
        if echo "$modified_block" | grep -qE '^## How to work here'; then
          target_header="## How to work here"
        elif echo "$modified_block" | grep -qE '^## Build'; then
          # Match the actual heading line so we substitute against the
          # exact text (could be `## Build` or `## Build commands`).
          target_header=$(echo "$modified_block" | grep -E '^## Build' | head -1)
        fi
        if [[ -n "$target_header" ]]; then
          # `env` ensures the variables reach awk's process environment.
          # The previous `VAR=val \ modified_block=$(awk ...)` form
          # bound them as shell-local and never exported, so awk's
          # ENVIRON saw empty strings and the insertion silently no-op'd.
          # Single-quotes around the awk script are intentional — that's
          # how you embed an awk program in shell. ENVIRON pulls the
          # variables in from the surrounding `env` prefix.
          # shellcheck disable=SC2016
          modified_block=$(env \
            NYANN_AWK_CMD="- \`$content\`" \
            NYANN_AWK_ME="$MARKER_END" \
            NYANN_AWK_HEADER="$target_header" \
            awk '
              BEGIN {
                cmd    = ENVIRON["NYANN_AWK_CMD"]
                me     = ENVIRON["NYANN_AWK_ME"]
                header = ENVIRON["NYANN_AWK_HEADER"]
              }
              $0 == header { print; found=1; next }
              found && /^$/ { print cmd; print; found=0; next }
              found && /^## / { print cmd; print ""; found=0 }
              { print }
            ' <<<"$modified_block")
          # Only record success when an insertion target was found and
          # the block was rewritten. If neither `## How to work here`
          # nor `## Build*` exists, target_header stays empty above and
          # we skip the awk; recording into applied[] anyway would
          # claim a successful optimisation that never happened.
          applied=$(jq --arg a "add" --arg c "$content" --arg r "$reason" \
            '. + [{ action: $a, content: $c, reason: $r }]' <<<"$applied")
        fi
      fi
      ;;
  esac
done

# Reconstruct the full file with the modified block
before_block=$(sed -n "1,/${MARKER_START}/{ /${MARKER_START}/d; p; }" "$claudemd")
after_block=$(sed -n "/${MARKER_END}/,\${ /${MARKER_END}/d; p; }" "$claudemd")

new_content="${before_block}
${modified_block}
${after_block}"

# Trim excess blank lines
new_content=$(printf '%s\n' "$new_content" | sed '/^$/N;/^\n$/d')

# Write to temp to get accurate byte count
opt_tmp=$(mktemp -t nyann-claudemd-opt.XXXXXX)
trap 'rm -f "$opt_tmp"' EXIT
printf '%s\n' "$new_content" > "$opt_tmp"
bytes_after=$(wc -c < "$opt_tmp" | tr -d ' ')
savings=$((bytes_before - bytes_after))
[[ "$savings" -lt 0 ]] && savings=0

HARD_CAP="${NYANN_CLAUDEMD_HARD_CAP_BYTES:-8192}"
if [[ "$bytes_after" -gt "$HARD_CAP" && "$force" != "true" ]]; then
  nyann::die "optimized CLAUDE.md ($bytes_after bytes) exceeds 8KB hard cap — use --force to override"
fi

if [[ "$dry_run" == "true" ]]; then
  rm -f "$opt_tmp"
  nyann::log "dry-run: would save $savings bytes"
  jq -n --argjson applied "$applied" --argjson before "$bytes_before" \
    --argjson after "$bytes_after" --argjson savings "$savings" \
    '{ dry_run: true, applied: $applied, bytes_before: $before, bytes_after: $after, savings: $savings }'
else
  [[ -L "$claudemd" ]] && nyann::die "refusing to write CLAUDE.md via symlink: $claudemd"
  mv "$opt_tmp" "$claudemd"

  # Update last_optimized timestamp
  usage_file="$target/memory/claudemd-usage.json"
  if [[ -f "$usage_file" ]]; then
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    usage_tmp=$(mktemp -t "nyann-usage.XXXXXX")
    if jq --arg ts "$timestamp" '.last_optimized = $ts' "$usage_file" > "$usage_tmp"; then
      mv "$usage_tmp" "$usage_file"
    else
      rm -f "$usage_tmp"
    fi
  fi

  nyann::log "optimized CLAUDE.md: saved $savings bytes ($rec_count recommendations applied)"
  jq -n --argjson applied "$applied" --argjson before "$bytes_before" \
    --argjson after "$bytes_after" --argjson savings "$savings" \
    '{ dry_run: false, applied: $applied, bytes_before: $before, bytes_after: $after, savings: $savings }'
fi
