#!/usr/bin/env bash
# Detector: missing IaC lockfile (severity medium). One finding per unit:
#
#   - A Terraform directory containing `.tf` files but no `.terraform.lock.hcl`.
#   - A Helm chart (Chart.yaml) declaring `dependencies:` but with no
#     `Chart.lock` alongside.
#   - A Pulumi project (Pulumi.yaml) without locked plugin versions
#     (no Pulumi.<stack> resource lock / no `plugins:` pin in Pulumi.yaml).
#
# Invoked once per scanned file by the orchestrator. To emit exactly ONE
# finding per directory/unit (not one per .tf file), the detector only acts
# when the current file is the *anchor* file for its unit — for Terraform
# that's the lexically-first `.tf` in the directory.
#
# Usage: missing-lockfile.sh --target <dir> --file <relpath>
# Emits NDJSON Finding objects on stdout. Exits 0 on any guard failure.

target=""; file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --file)     file="${2-}"; shift 2 ;;
    --file=*)   file="${1#--file=}"; shift ;;
    *) shift ;;
  esac
done

[[ -n "$target" && -n "$file" ]] || exit 0
abs="$target/$file"
[[ -f "$abs" ]] || exit 0

base="$(basename "$file")"
dir="$(dirname "$file")"
[[ "$dir" == "." ]] && dir=""
absdir="$target${dir:+/$dir}"

emit() {
  # emit <line> <message> <current> <expected> <hint>
  local line="$1" message="$2" current="$3" expected="$4" hint="$5"
  jq -n --arg kind "missing-lockfile" \
        --arg file "$file" \
        --argjson line "$line" \
        --arg severity "medium" \
        --arg message "$message" \
        --arg current "$current" \
        --arg expected "$expected" \
        --arg hint "$hint" \
        '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, expected:$expected, fix_hint:$hint}'
}

# --- Terraform ---------------------------------------------------------------
if [[ "$file" == *.tf ]]; then
  # Anchor: only act on the lexically-first .tf in this directory, so a
  # multi-file module yields a single finding.
  anchor=""
  while IFS= read -r tf; do
    anchor="$(basename "$tf")"
    break
  done < <( find "$absdir" -maxdepth 1 -type f -name '*.tf' 2>/dev/null | LC_ALL=C sort )
  [[ "$base" == "$anchor" ]] || exit 0

  if [[ ! -f "$absdir/.terraform.lock.hcl" ]]; then
    emit 1 \
      "Terraform unit '${dir:-.}' has .tf files but no .terraform.lock.hcl" \
      "no .terraform.lock.hcl" ".terraform.lock.hcl committed" \
      "run 'terraform init' and commit the generated .terraform.lock.hcl"
  fi
fi

# --- Helm --------------------------------------------------------------------
if [[ "$base" == "Chart.yaml" ]]; then
  # Only flag charts that actually declare dependencies (a depless chart
  # legitimately has no Chart.lock).
  if grep -qE '^dependencies:' "$abs" 2>/dev/null; then
    if [[ ! -f "$absdir/Chart.lock" ]]; then
      emit 1 \
        "Helm chart '${dir:-.}' declares dependencies but has no Chart.lock" \
        "no Chart.lock" "Chart.lock committed" \
        "run 'helm dependency update' and commit the generated Chart.lock"
    fi
  fi
fi

# --- Pulumi ------------------------------------------------------------------
if [[ "$base" == "Pulumi.yaml" || "$base" == "Pulumi.yml" ]]; then
  # Pulumi has no single canonical on-disk lockfile; locked plugin versions
  # live under a `plugins:` block in Pulumi.yaml (or a workspace plugin
  # cache). Flag a project that pins no plugin versions at all.
  if ! grep -qE '^plugins:' "$abs" 2>/dev/null; then
    emit 1 \
      "Pulumi project '${dir:-.}' does not lock plugin versions" \
      "no plugins: block" "plugins: with pinned versions" \
      "add a 'plugins:' block to Pulumi.yaml pinning provider plugin versions"
  fi
fi

exit 0
