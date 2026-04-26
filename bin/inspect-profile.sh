#!/usr/bin/env bash
# inspect-profile.sh — explain what a profile enables in plain English.
#
# Usage: inspect-profile.sh <name> [--user-root <dir>]
#
# Resolves the profile via bin/load-profile.sh (user overrides starter),
# then pretty-prints each section: stack assumptions, branching strategy,
# hook list with friendly descriptions, extras, documentation plan.
#
# Exits 0 on success; 2 when the profile isn't found (prints available
# list).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

name=""
user_root="${HOME}/.claude/nyann"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-root)   user_root="${2:-}"; shift 2 ;;
    --user-root=*) user_root="${1#--user-root=}"; shift ;;
    -h|--help)     sed -n '3,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    --*)           nyann::die "unknown flag: $1" ;;
    *)
      [[ -z "$name" ]] || nyann::die "unexpected extra arg: $1"
      name="$1"; shift
      ;;
  esac
done

[[ -n "$name" ]] || nyann::die "usage: inspect-profile.sh <name>"

# Friendly descriptions for each hook id we know about. Any unknown id
# is printed with a generic "custom hook" blurb.
hook_blurb() {
  case "$1" in
    block-main)           echo "refuse direct commits to main/master" ;;
    gitleaks)             echo "scan staged changes for secrets" ;;
    conventional-commits) echo "enforce Conventional Commits format" ;;
    commitizen)           echo "commitizen runs on commit-msg for Conventional Commits" ;;
    lint-staged)          echo "run formatter/linter on only the staged JS/TS files" ;;
    eslint)               echo "ESLint runs on staged JS/TS" ;;
    prettier)             echo "Prettier formats staged JS/TS/MD/JSON/CSS" ;;
    ruff)                 echo "Ruff lints Python with --fix" ;;
    ruff-format)          echo "Ruff formats Python in place" ;;
    gofmt)                echo "gofmt on staged Go files" ;;
    go-vet)               echo "go vet catches suspicious Go constructs" ;;
    golangci-lint)        echo "golangci-lint aggregates Go linters" ;;
    fmt)                  echo "rustfmt on staged Rust files" ;;
    clippy)               echo "cargo clippy with --deny warnings" ;;
    swiftlint)            echo "lint Swift code for style and conventions" ;;
    swiftformat)          echo "format Swift code consistently" ;;
    ktlint)               echo "lint and format Kotlin code" ;;
    detekt)               echo "static analysis for Kotlin" ;;
    shellcheck)           echo "lint shell scripts for errors and portability" ;;
    shfmt)                echo "format shell scripts consistently" ;;
    tsc)                  echo "TypeScript type-check on staged .ts files" ;;
    mypy)                 echo "mypy type-checks Python" ;;
    black)                echo "Black formats Python" ;;
    trailing-whitespace)  echo "strip trailing whitespace" ;;
    *)                    echo "custom hook" ;;
  esac
}

# Load the profile. load-profile.sh emits JSON on stdout, logs to stderr —
# keep those separate so our JSON parse isn't polluted by log text.
tmp_profile=$(mktemp -t nyann-inspect.XXXXXX)
tmp_err=$(mktemp -t nyann-inspect-err.XXXXXX)
trap 'rm -f "$tmp_profile" "$tmp_err"' EXIT
if ! "${_script_dir}/load-profile.sh" "$name" --user-root "$user_root" > "$tmp_profile" 2> "$tmp_err"; then
  cat "$tmp_err" >&2
  rm -f "$tmp_profile" "$tmp_err"
  exit 2
fi
# Even on success, relay any warnings (e.g. "user profile shadows starter").
[[ -s "$tmp_err" ]] && cat "$tmp_err" >&2
rm -f "$tmp_err"

p=$(cat "$tmp_profile")
rm -f "$tmp_profile"

# --- render ---------------------------------------------------------------

{
  echo "Profile: $(jq -r '.name' <<<"$p")"
  desc=$(jq -r '.description // ""' <<<"$p")
  [[ -n "$desc" && "$desc" != "null" ]] && echo "  ${desc}"

  # Surface any shadowing the loader recorded into _meta so the user
  # notices when their personal profile silently overrides a starter
  # they thought was active. The loader also writes a stderr log line,
  # but stderr is easy to lose; this banner sits at the top of the
  # rendered output where it's hard to miss.
  shadowed_starter=$(jq -r '._meta.shadowed_starter // ""' <<<"$p")
  if [[ -n "$shadowed_starter" ]]; then
    echo ""
    echo "  ⚠ This profile shadows a built-in starter at:"
    echo "     ${shadowed_starter}"
    echo "     (delete the user file to fall back to the starter.)"
  fi
  shadowed_team_count=$(jq -r '._meta.shadowed_team | length // 0' <<<"$p")
  if [[ "$shadowed_team_count" -gt 0 ]]; then
    echo ""
    echo "  ⚠ This profile shadows ${shadowed_team_count} team profile(s):"
    jq -r '._meta.shadowed_team[] | "     " + .' <<<"$p"
  fi
  echo ""

  echo "Stack:"
  echo "  Language         $(jq -r '.stack.primary_language' <<<"$p")"
  fw=$(jq -r '.stack.framework // "(none)"' <<<"$p");       echo "  Framework        $fw"
  pm=$(jq -r '.stack.package_manager // "(none)"' <<<"$p"); echo "  Package manager  $pm"
  echo ""

  echo "Branching:"
  echo "  Strategy         $(jq -r '.branching.strategy' <<<"$p")"
  echo "  Base branches    $(jq -r '.branching.base_branches | join(", ")' <<<"$p")"
  if jq -e '.branching.branch_name_patterns' <<<"$p" >/dev/null 2>&1; then
    echo "  Patterns:"
    jq -r '.branching.branch_name_patterns | to_entries[] | "    \(.key): \(.value)"' <<<"$p"
  fi
  echo ""

  echo "Hooks:"
  for slot in pre_commit commit_msg pre_push; do
    ids=$(jq -r --arg s "$slot" '.hooks[$s] // [] | .[]' <<<"$p")
    [[ -z "$ids" ]] && continue
    echo "  [${slot//_/-}]"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      printf '    - %-20s %s\n' "$id" "$(hook_blurb "$id")"
    done <<<"$ids"
  done
  echo ""

  echo "Extras:"
  jq -r '.extras | to_entries[] | "  " + .key + (if .value then " : on" else " : off" end)' <<<"$p" \
    || echo "  (none declared)"
  echo ""

  echo "Conventions:"
  echo "  Commit format    $(jq -r '.conventions.commit_format // "(unset)"' <<<"$p")"
  if jq -e '.conventions.commit_scopes' <<<"$p" >/dev/null 2>&1; then
    echo "  Commit scopes    $(jq -r '.conventions.commit_scopes | join(", ")' <<<"$p")"
  fi
  echo ""

  echo "Documentation:"
  echo "  Scaffold types   $(jq -r '.documentation.scaffold_types | join(", ")' <<<"$p")"
  echo "  Storage strategy $(jq -r '.documentation.storage_strategy' <<<"$p")"
  echo "  CLAUDE.md mode   $(jq -r '.documentation.claude_md_mode' <<<"$p")"
  echo "  Size budget (KB) $(jq -r '.documentation.claude_md_size_budget_kb // 3' <<<"$p")"
  staleness=$(jq -r '.documentation.staleness_days // "(off)"' <<<"$p")
  echo "  Staleness        $staleness"

  if jq -e '.github' <<<"$p" >/dev/null 2>&1; then
    echo ""
    echo "GitHub integration:"
    jq -r '.github | to_entries[] | "  " + .key + " : " + (.value | tostring)' <<<"$p"
  fi
}
