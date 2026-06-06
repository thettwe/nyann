#!/usr/bin/env bash
# terraform-docs — regenerate the README.md of any module whose .tf files
# were ALREADY staged for this commit. Soft-skip when terraform-docs is
# not installed.
#
# Critical: only re-stage READMEs of modules whose .tf files appear in the
# staged set. Touching modules whose .tf files are still unstaged (or
# whose READMEs the user is intentionally leaving out) would silently
# pull unrelated changes into the commit and break `git add -p` workflows.
set -e
if ! command -v terraform-docs >/dev/null 2>&1; then
  echo "[nyann iac] terraform-docs not installed — skipping (https://terraform-docs.io)" >&2
  exit 0
fi

# Build the set of modules with staged .tf changes. `git diff --cached`
# is the source of truth for what's in the upcoming commit.
staged_tf=$(git diff --cached --name-only --diff-filter=ACMR -- 'modules/*/**.tf' 2>/dev/null || true)
[[ -n "$staged_tf" ]] || exit 0

# Derive the module directory of each staged .tf as the directory that
# actually CONTAINS it (`dirname`), not a fixed two-segment depth. The
# deep layout detect-iac.sh advertises (e.g. modules/aws/networking/main.tf)
# would otherwise be missed when we assumed modules/<name> only.
modules=$(printf '%s\n' "$staged_tf" \
  | while IFS= read -r f; do [[ -n "$f" ]] && dirname "$f"; done \
  | sort -u)
[[ -n "$modules" ]] || exit 0

while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  [[ -d "$dir" ]] || continue
  if compgen -G "${dir}/*.tf" >/dev/null 2>&1; then
    terraform-docs markdown table --output-file README.md --output-mode inject "$dir" >/dev/null
    # Only stage this module's README — never the broader `modules/*/README.md`
    # glob that would sweep in unrelated unstaged READMEs.
    if [[ -f "${dir}/README.md" ]]; then
      git add -- "${dir}/README.md" 2>/dev/null || true
    fi
  fi
done <<< "$modules"
exit 0
