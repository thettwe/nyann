discover_workspaces() {
  # Prints one workspace dir per line on stdout.
  case "$monorepo_tool" in
    '"pnpm-workspaces"')
      # pnpm-workspace.yaml → `packages:` list of globs.
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$path" <<'PY' || true
import os, sys, glob
try:
    import yaml
except ImportError:
    sys.exit(0)
root = sys.argv[1]
cfg = os.path.join(root, 'pnpm-workspace.yaml')
if not os.path.exists(cfg):
    sys.exit(0)
with open(cfg) as f:
    doc = yaml.safe_load(f) or {}
for pat in (doc.get('packages') or []):
    full = os.path.join(root, pat)
    for match in sorted(glob.glob(full)):
        if os.path.isdir(match):
            print(os.path.relpath(match, root))
PY
      fi
      ;;
    '"turbo"'|'"nx"'|'"lerna"')
      # These typically piggyback on yarn/npm workspaces in package.json or a
      # `packages` glob in their own config. Read package.json.workspaces first.
      if [[ -f "$path/package.json" ]]; then
        jq -r '
          (.workspaces // []) as $w
          | (if ($w | type) == "object" then ($w.packages // []) else $w end)[]
        ' "$path/package.json" 2>/dev/null | while IFS= read -r pat; do
          [[ -z "$pat" ]] && continue
          [[ "$pat" == /* || "$pat" == *".."* ]] && continue
          # Scope IFS to newline-only so a workspace pattern like
          # "apps and libs/*" doesn't get word-split on spaces during
          # the unquoted glob expansion. Default IFS=$' \t\n' would
          # split the single pattern into three globs. The IFS change
          # is scoped to this pipe subshell — no restore needed.
          IFS=$'\n'
          for match in "$path"/$pat; do
            [[ -d "$match" ]] && echo "${match#"$path"/}"
          done
        done
      fi
      ;;
  esac
}
