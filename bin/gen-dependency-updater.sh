#!/usr/bin/env bash
# gen-dependency-updater.sh — emit a Dependabot or Renovate config.
#
# Usage:
#   bin/gen-dependency-updater.sh
#     --updater <dependabot|renovate>
#     --ecosystem <npm|pip|gomod|cargo|bundler|composer|maven|gradle|pub|nuget|mix|swift|docker|github-actions>
#         [--ecosystem <other> ...]
#     [--directory <path>]               # default "/"
#     [--target <repo>]                  # default $PWD (only used when --apply)
#     [--apply]                          # write the config; default is preview-to-stdout
#     [--force-overwrite]                # idempotency override (see below)
#     [--schedule <daily|weekly|monthly>]   # default "weekly"
#     [--grouping <off|minor-patch|all>]    # default "minor-patch"
#     [--open-prs <int>]                 # 1-25, default 5
#
# Default behavior is preview-only — without `--apply`, the rendered
# config is printed to stdout (Dependabot YAML or Renovate JSON) and
# nothing is written to the filesystem. Matches the preview-before-
# mutate convention used by every other generator in nyann.
#
# When `--apply` is passed, the file lands at:
#   - dependabot: <target>/.github/dependabot.yml
#   - renovate:   <target>/renovate.json
#
# Idempotency: if the destination file already exists AND its content
# differs from the rendered output, the script prints a unified diff
# to stderr and refuses to overwrite — unless `--force-overwrite` is
# also passed. If existing content is byte-identical, the apply is a
# no-op and exit is 0. This matches install-hooks.sh / gitignore-
# combiner.sh idempotency semantics.
#
# Exit codes:
#   0 — preview rendered (no --apply) OR apply succeeded (no diff, or
#       --force-overwrite resolved a diff)
#   1 — bad input
#   3 — apply blocked because target file differs and --force-overwrite
#       was not passed (rendered diff already on stderr)

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

# --- arg parsing -------------------------------------------------------------

updater=""
ecosystems=()
directories=()
target=""
apply=false
force_overwrite=false
schedule="weekly"
grouping="minor-patch"
open_prs=5

# Track per-ecosystem directory: since --ecosystem can repeat, we let
# the caller pair --ecosystem with an optional --directory before the
# next --ecosystem. Easier: collect parallel arrays, default
# `directory` to "/" when a --directory was not supplied for an
# ecosystem instance.
_pending_directory=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --updater)         updater="${2:-}"; shift 2 ;;
    --updater=*)       updater="${1#--updater=}"; shift ;;
    --ecosystem)
      ecosystems+=("${2:-}")
      directories+=("${_pending_directory:-/}")
      _pending_directory=""
      shift 2
      ;;
    --ecosystem=*)
      ecosystems+=("${1#--ecosystem=}")
      directories+=("${_pending_directory:-/}")
      _pending_directory=""
      shift
      ;;
    --directory)       _pending_directory="${2:-/}"; shift 2 ;;
    --directory=*)     _pending_directory="${1#--directory=}"; shift ;;
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --apply)           apply=true; shift ;;
    --force-overwrite) force_overwrite=true; shift ;;
    --schedule)        schedule="${2:-weekly}"; shift 2 ;;
    --schedule=*)      schedule="${1#--schedule=}"; shift ;;
    --grouping)        grouping="${2:-minor-patch}"; shift 2 ;;
    --grouping=*)      grouping="${1#--grouping=}"; shift ;;
    --open-prs)        open_prs="${2:-5}"; shift 2 ;;
    --open-prs=*)      open_prs="${1#--open-prs=}"; shift ;;
    -h|--help)         sed -n '3,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# A --directory placed AFTER the last --ecosystem has no ecosystem to
# pair with: it stays buffered in _pending_directory and is silently
# dropped. Warn so the operator notices the typo rather than getting a
# config that ignores their intended directory.
if [[ -n "$_pending_directory" ]]; then
  nyann::warn "trailing --directory '$_pending_directory' has no following --ecosystem; ignored"
fi

# --- validate ----------------------------------------------------------------

case "$updater" in
  dependabot|renovate) ;;
  "") nyann::die "--updater is required (dependabot|renovate)" ;;
  *)  nyann::die "--updater must be dependabot or renovate, got: $updater" ;;
esac

if [[ ${#ecosystems[@]} -eq 0 ]]; then
  nyann::die "at least one --ecosystem is required"
fi

# Validate each ecosystem against the schema's enum. Out-of-list values
# would render but produce a Dependabot config GitHub rejects on commit
# — better to fail fast here.
for eco in "${ecosystems[@]}"; do
  case "$eco" in
    npm|pip|gomod|cargo|bundler|composer|maven|gradle|pub|nuget|mix|swift|docker|github-actions) ;;
    *) nyann::die "unknown ecosystem: $eco (see schemas/dependency-updater-config.schema.json for the allowlist)" ;;
  esac
done

# Validate directory paths: each must start with /. Dependabot rejects
# anything else, and Renovate doesn't care either way — uniform format
# keeps the rendered output consistent.
for dir in "${directories[@]}"; do
  [[ "$dir" == /* ]] || nyann::die "--directory must start with '/', got: $dir"
done

case "$schedule" in daily|weekly|monthly) ;; *)
  nyann::die "--schedule must be daily, weekly, or monthly, got: $schedule" ;;
esac

case "$grouping" in off|minor-patch|all) ;; *)
  nyann::die "--grouping must be off, minor-patch, or all, got: $grouping" ;;
esac

[[ "$open_prs" =~ ^[0-9]+$ ]] || nyann::die "--open-prs must be an integer, got: $open_prs"
(( open_prs >= 1 && open_prs <= 25 )) || nyann::die "--open-prs must be 1-25, got: $open_prs"

if $apply; then
  [[ -n "$target" ]] || nyann::die "--apply requires --target <repo>"
  [[ -d "$target" ]] || nyann::die "--target must be an existing directory: $target"
  target="$(cd "$target" && pwd -P)"
fi

# --- snapshot tag ------------------------------------------------------------
# Embed the nyann version in the generated file so an operator triaging
# a stale config can tell when it was last regenerated. We read it from
# .claude-plugin/plugin.json so the value stays in lockstep with the
# release. Fail soft: missing version becomes "unknown".
plugin_json="${_script_dir}/../.claude-plugin/plugin.json"
nyann_version="unknown"
if [[ -f "$plugin_json" ]] && nyann::has_cmd jq; then
  nyann_version=$(jq -r '.version // "unknown"' "$plugin_json" 2>/dev/null || echo unknown)
fi

# --- renderers ---------------------------------------------------------------

render_dependabot() {
  printf '# Dependabot config — generated by nyann %s (gen-dependency-updater.sh).\n' "$nyann_version"
  printf '# Re-run the generator to refresh; edits here will diff against the\n'
  printf '# template on the next preview pass.\n'
  printf '#\n'
  printf '# Grouping policy: %s\n' "$grouping"
  printf '# Schedule:        %s\n' "$schedule"
  printf '# Open-PR cap:     %s per ecosystem\n' "$open_prs"
  printf 'version: 2\n'
  printf 'updates:\n'

  local i
  for ((i=0; i<${#ecosystems[@]}; i++)); do
    local eco="${ecosystems[$i]}" dir="${directories[$i]}"
    printf '  - package-ecosystem: "%s"\n' "$eco"
    printf '    directory: "%s"\n' "$dir"
    printf '    schedule:\n'
    printf '      interval: "%s"\n' "$schedule"
    printf '    open-pull-requests-limit: %s\n' "$open_prs"
    printf '    labels:\n'
    printf '      - "dependencies"\n'
    printf '      - "automated"\n'
    # Grouping: each Dependabot group is a named bundle. minor-patch
    # groups the two safest semver tiers; majors stay separate because
    # they often need review for breaking changes regardless of size.
    case "$grouping" in
      minor-patch)
        printf '    groups:\n'
        printf '      minor-and-patch:\n'
        printf '        update-types:\n'
        printf '          - "minor"\n'
        printf '          - "patch"\n'
        ;;
      all)
        printf '    groups:\n'
        printf '      all-updates:\n'
        printf '        update-types:\n'
        printf '          - "major"\n'
        printf '          - "minor"\n'
        printf '          - "patch"\n'
        ;;
      off)
        # No groups: Dependabot defaults to one PR per update.
        ;;
    esac
  done
}

render_renovate() {
  # Renovate uses JSON; jq builds it so the output is well-formed and
  # we don't have to hand-quote anything. config:recommended pulls in
  # the modern best-practices preset (auto-detect ecosystems, group
  # minor-patch by default, security alerts enabled).
  local ecosystems_csv
  ecosystems_csv=$(IFS=,; printf '%s' "${ecosystems[*]}")

  jq -n \
    --arg version "$nyann_version" \
    --arg ecos "$ecosystems_csv" \
    --arg schedule "$schedule" \
    --arg grouping "$grouping" \
    --argjson open_prs "$open_prs" \
    '
    {
      "$schema": "https://docs.renovatebot.com/renovate-schema.json",
      "$comment": (
        "Generated by nyann " + $version + " (gen-dependency-updater.sh). " +
        "Detected ecosystems: " + $ecos + ". " +
        "Re-run the generator to refresh; edits here will diff against " +
        "the template on the next preview pass."
      ),
      "extends": [
        "config:recommended"
      ],
      "labels": ["dependencies", "automated"],
      "schedule": (
        # Renovate natural-language schedules — keep the three branches
        # consistent. Earlier `* 0-3 * * *` for daily was a cron typo
        # that meant "every minute in the 0-3 window" (240 scans/day),
        # not "once daily in the quiet window".
        if $schedule == "daily" then ["before 5am every day"]
        elif $schedule == "monthly" then ["before 5am on the first day of the month"]
        else ["before 5am on Monday"]
        end
      ),
      "prHourlyLimit": 0,
      "prConcurrentLimit": $open_prs,
      "packageRules": (
        if $grouping == "minor-patch" then [{
          "groupName": "minor and patch updates",
          "matchUpdateTypes": ["minor", "patch"]
        }]
        elif $grouping == "all" then [{
          "groupName": "all updates",
          "matchUpdateTypes": ["major", "minor", "patch"]
        }]
        else []
        end
      )
    }'
}

# --- assemble ----------------------------------------------------------------

rendered=""
case "$updater" in
  dependabot) rendered="$(render_dependabot)" ;;
  renovate)   rendered="$(render_renovate)"   ;;
esac

# --- preview vs. apply -------------------------------------------------------

if ! $apply; then
  printf '%s\n' "$rendered"
  exit 0
fi

dest=""
dest_dir_rel=""
case "$updater" in
  dependabot) dest="$target/.github/dependabot.yml"; dest_dir_rel=".github" ;;
  renovate)   dest="$target/renovate.json";           dest_dir_rel=""        ;;
esac

# Reject symlink-as-destination, matching the bootstrap/scaffold-docs
# discipline. A symlinked dependabot.yml pointing outside the repo is
# how a hostile config can redirect generated content to /etc/cron.d/.
if [[ -L "$dest" ]]; then
  nyann::die "refusing to write through a symlink: $dest"
fi

# Symlink-mediated escape guard: `mkdir -p` happily follows symlinks at
# intermediate components, so the leaf-only check above can't catch a
# pre-placed `$target/.github → /etc/` symlink. Walk the ancestry
# explicitly via the shared helper. For Renovate (writes at repo root),
# there's no intermediate directory to mkdir, so the helper is skipped.
if [[ -n "$dest_dir_rel" ]]; then
  if ! nyann::safe_mkdir_under_target "$target" "$dest_dir_rel" >/dev/null; then
    nyann::die "refusing to write $dest: ancestor is a symlink or mkdir failed"
  fi
fi

# Idempotency: identical-content apply is a no-op. Different-content
# apply requires --force-overwrite + emits a diff to stderr first.
if [[ -f "$dest" ]]; then
  existing="$(cat "$dest")"
  if [[ "$existing" == "$rendered" ]]; then
    nyann::log "unchanged: $dest already matches the generated config"
    exit 0
  fi

  # Different. Print the diff so the operator can see what would change
  # before deciding to re-run with --force-overwrite.
  {
    printf 'gen-dependency-updater: existing file differs from generated output:\n'
    diff -u <(printf '%s\n' "$existing") <(printf '%s\n' "$rendered") || true
  } >&2

  if ! $force_overwrite; then
    nyann::warn "$dest exists and differs; re-run with --force-overwrite to replace"
    exit 3
  fi
fi

printf '%s\n' "$rendered" > "$dest"
nyann::log "wrote $dest ($updater config, ${#ecosystems[@]} ecosystem(s))"
