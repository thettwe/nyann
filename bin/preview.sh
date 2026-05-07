#!/usr/bin/env bash
# preview.sh — render an ActionPlan for human confirmation.
#
# Usage:
#   preview.sh --plan <path>                   # render to stderr, emit plan to stdout
#   preview.sh --plan <path> --skip <path> ... # skip entries before emitting
#   preview.sh --plan <path> --decision no     # abort cleanly with exit 1
#   preview.sh --plan <path> --decision yes    # same as default
#   preview.sh --plan <path> --emit-sha256     # print canonical SHA-256 only
#   preview.sh --plan <path> --json            # emit PreviewResult JSON only (no stderr render)
#
# Contract: preview is read-only. It never touches the filesystem. The emitted
# plan on stdout is what the orchestrator will execute. Rendering goes to
# stderr so callers can capture plan JSON cleanly.
#
# --json mode emits a single PreviewResult object on stdout
# (schemas/preview-result.schema.json) carrying plan + summary + plan_sha256
# + skips_applied. No stderr render. Mutually exclusive with --emit-sha256.
#
# Integrity binding:
#   The SHA-256 of the canonical plan (jq -Sc) is printed on stderr right
#   after the rendered summary. Orchestrators pass this hex to
#   bootstrap.sh via --plan-sha256; bootstrap recomputes and refuses to
#   run when the plan file changed between preview and execute. This
#   defeats a TOCTOU swap where the user confirms one plan and the
#   orchestrator reads a different one off disk.
#
# Skip semantics:
#   --skip <path>   removes a write whose `.path` matches (anywhere in writes[])
#   Multiple --skip flags compose. Commands and remote[] are not skippable in
#   v1 (they're derived from writes); later tasks may add --skip-cmd.

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

plan_path=""
decision=""
skips=()
emit_sha_only=false
json_out=false
diff_mode="auto"   # auto | full | off
diff_max_lines=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)          plan_path="${2:-}"; shift 2 ;;
    --plan=*)        plan_path="${1#--plan=}"; shift ;;
    --skip)          skips+=("${2:-}"); shift 2 ;;
    --skip=*)        skips+=("${1#--skip=}"); shift ;;
    --decision)      decision="${2:-}"; shift 2 ;;
    --decision=*)    decision="${1#--decision=}"; shift ;;
    --emit-sha256)   emit_sha_only=true; shift ;;
    --json)          json_out=true; shift ;;
    --no-diff)       diff_mode="off"; shift ;;
    --full-diff)     diff_mode="full"; shift ;;
    -h|--help)
      sed -n '3,32p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --emit-sha256 and --json both short-circuit stdout. They produce
# different payloads (raw hex vs full PreviewResult), so a caller that
# requested both has a mistake — die rather than silently picking one.
if $emit_sha_only && $json_out; then
  nyann::die "--emit-sha256 and --json are mutually exclusive"
fi

[[ -n "$plan_path" ]] || nyann::die "--plan is required"
[[ -f "$plan_path" ]] || nyann::die "plan not found: $plan_path"

plan_json="$(cat "$plan_path")"
jq -e 'type == "object" and has("writes") and has("commands") and has("remote")' <<<"$plan_json" >/dev/null \
  || nyann::die "plan does not match ActionPlan shape (writes/commands/remote required)"

# Apply skips. Guarded iteration — bash 3.2 + `set -u` treats accessing an
# empty array with "${a[@]}" as unbound.
if [[ ${#skips[@]} -gt 0 ]]; then
  for s in "${skips[@]}"; do
    plan_json="$(jq --arg p "$s" '
      .writes = (.writes | map(select(.path != $p)))
    ' <<<"$plan_json")"
  done
fi

# Honor decision: "no" exits 1 with a clean message, no stdout.
# In --json mode the same exit happens but with a structured payload so
# tooling can distinguish "user declined" from "preview crashed".
case "$decision" in
  no)
    if $json_out; then
      jq -nc '{declined: true, plan: null, summary: null, plan_sha256: "", skips_applied: []}'
    else
      printf '[nyann] plan declined. No changes made.\n' >&2
    fi
    exit 1
    ;;
  yes|"")
    ;;
  *)
    nyann::die "invalid --decision: $decision (want yes|no)"
    ;;
esac

# --- render to stderr --------------------------------------------------------
# Keep terse so 30+ line plans stay readable.
# Skipped in --json mode — a tooling consumer doesn't need the human
# render and reading mixed stderr+stdout is exactly the brittleness
# --json exists to remove.

if ! $json_out; then
{
  printf 'Planned changes:\n'
  jq -r '
    .writes[]
    | "  " + (.action | ascii_upcase | (. + ":         ")[0:10]) + " " + .path
      + ( if (.bytes // null) != null then "  (" + (.bytes|tostring) + " B)" else "" end )
  ' <<<"$plan_json"

  # For each merge entry that carries a preview_blob (rendered via
  # bin/render-plan.sh), show a unified diff of what's about to change.
  # `auto` mode truncates to the first $diff_max_lines lines per file
  # so a 200-line CLAUDE.md regen stays readable; --full-diff lifts
  # the cap; --no-diff skips this block entirely. Works only when the
  # current file actually exists — diffing against /dev/null for new-
  # file merges would just print the entire blob, which the size line
  # already conveys.
  if [[ "$diff_mode" != "off" ]]; then
    while IFS=$'\t' read -r path blob current_bytes; do
      [[ -z "$path" || -z "$blob" ]] && continue
      [[ ! -f "$blob" ]] && continue
      printf '\n--- %s diff (current %s B → merged) ---\n' "$path" "$current_bytes"
      cur_file="/dev/null"
      # The plan's `.path` is repo-relative; resolve against $PWD only
      # if no absolute reference is encoded. preview.sh runs in the
      # caller's cwd (the target repo) by convention.
      if [[ -f "$path" ]]; then
        cur_file="$path"
      elif [[ -n "${NYANN_PREVIEW_TARGET:-}" && -f "${NYANN_PREVIEW_TARGET}/$path" ]]; then
        cur_file="${NYANN_PREVIEW_TARGET}/$path"
      fi
      if [[ "$diff_mode" == "full" ]]; then
        diff -u "$cur_file" "$blob" 2>/dev/null || true
      else
        diff -u "$cur_file" "$blob" 2>/dev/null | awk -v max="$diff_max_lines" '
          NR <= max { print }
          NR == max + 1 { print "  …(truncated; pass --full-diff to see all)" }
        ' || true
      fi
    done < <(
      jq -r '
        .writes[]
        | select(.action == "merge" and (.preview_blob // "") != "")
        | [.path, .preview_blob, (.current_bytes // 0)]
        | @tsv
      ' <<<"$plan_json"
    )
  fi

  if [[ "$(jq '.commands | length' <<<"$plan_json")" != "0" ]]; then
    printf '\nCommands to run:\n'
    jq -r '.commands[] | "  $ " + .cmd + ( if .cwd then "   # cwd=" + .cwd else "" end )' <<<"$plan_json"
  fi

  if [[ "$(jq '.remote | length' <<<"$plan_json")" != "0" ]]; then
    printf '\nRemote changes:\n'
    jq -r '.remote[] | "  " + .type + ( if .branch then " on branch " + .branch else "" end )' <<<"$plan_json"
  fi

  printf '\nProceed? (yes / no / skip <path>)\n'
} >&2
fi

# --- integrity binding -------------------------------------------------------
# Compute SHA-256 of the canonicalised plan (sorted keys, compact) and
# emit on stderr so the operator sees it alongside the render, and so
# skill-layer callers can capture it for --plan-sha256 on bootstrap.
# Canonicalisation is important: two semantically-identical plans with
# different whitespace should agree.
plan_canon=$(jq -Sc . <<<"$plan_json")
if command -v shasum >/dev/null 2>&1; then
  plan_sha256=$(printf '%s' "$plan_canon" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  plan_sha256=$(printf '%s' "$plan_canon" | sha256sum | awk '{print $1}')
else
  plan_sha256=""
  nyann::warn "neither shasum nor sha256sum on PATH; plan integrity binding disabled"
fi

if [[ -n "$plan_sha256" ]] && ! $json_out; then
  printf 'Plan SHA-256: %s\n' "$plan_sha256" >&2
  # The SHA is computed over the POST-skip plan. If the
  # caller used --skip and then pipes $plan_path (the unfiltered file)
  # into `bootstrap --plan-sha256`, the hash won't match and bootstrap
  # will reject. The skill-layer workflow must either (a) write the
  # filtered plan to a new temp file and hash that (as we print),
  # then pass BOTH the new path and the hash to bootstrap, or (b)
  # skip `--plan-sha256` entirely for skip-filtered plans. Warn
  # loudly so a human running this notices.
  if [[ ${#skips[@]} -gt 0 ]]; then
    # Backticks in the user-facing message are literal markdown, not
    # shell command substitution. Single-quoting is intentional.
    # shellcheck disable=SC2016
    printf 'Note: --skip was applied; the SHA above is of the filtered plan. Pass bootstrap a file whose bytes match this hash (e.g. `preview.sh ... > new-plan.json` and use that path), not the original plan.\n' >&2
  fi
fi

# --emit-sha256 short-circuit: print only the hex on stdout and exit.
# Lets an orchestrator capture the hash without re-piping the whole
# plan through its own hasher.
if $emit_sha_only; then
  printf '%s\n' "$plan_sha256"
  exit 0
fi

# --- emit plan on stdout -----------------------------------------------------
# Two stdout shapes: the legacy bare ActionPlan (default) for
# bootstrap.sh's stdin, or a full PreviewResult object (--json) for
# tooling. The PreviewResult derives its summary from the post-skip
# plan in a single jq invocation so write_count / actions / total_bytes
# stay in sync without a second pass.

if $json_out; then
  # Build skips_applied: only paths that actually matched a write in
  # the unfiltered plan. Reading the original file (not $plan_json
  # which has them removed) lets us distinguish "user typo" from
  # "user skipped a real entry" — only the latter is reported.
  if [[ ${#skips[@]} -gt 0 ]]; then
    orig_paths=$(jq -c '[.writes[].path]' "$plan_path")
    skips_json=$(printf '%s\n' "${skips[@]}" | jq -R . \
      | jq -sc --argjson orig "$orig_paths" 'map(select(. as $s | $orig | index($s)))')
  else
    skips_json='[]'
  fi

  jq -nc \
    --argjson plan "$plan_json" \
    --arg sha "$plan_sha256" \
    --argjson skips "$skips_json" \
    '
      ($plan.writes | map(.action) | reduce .[] as $a ({}; .[$a] = (.[$a] // 0) + 1)) as $hist |
      {
        plan: $plan,
        summary: {
          write_count:   ($plan.writes | length),
          command_count: ($plan.commands | length),
          remote_count:  ($plan.remote | length),
          actions:       $hist,
          total_bytes:   ($plan.writes | map(.bytes // 0) | add // 0)
        },
        plan_sha256: $sha,
        skips_applied: $skips
      }
    '
  exit 0
fi

printf '%s\n' "$plan_json"
