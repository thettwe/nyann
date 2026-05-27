# --- shared helpers (used by both --check and --apply) ----------------------

branches_for_strategy() {
  case "$strategy" in
    github-flow) echo "main" ;;
    gitflow)     printf '%s\n' main develop ;;
    trunk-based) echo "main" ;;
    *)           echo "main" ;;
  esac
}

# Locate a CODEOWNERS file at any conventional path. Returns the path
# (relative to target) on stdout, empty string when absent. Used by
# the --check codeowners_gate section.
codeowners_path() {
  for p in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
    [[ -f "$target/$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}
