#!/usr/bin/env bash
# install-hooks.sh — install nyann's git hooks into a repo.
#
# Usage: install-hooks.sh --target <repo> [--core] [--jsts] [--python]
#                                          [--go] [--rust] [--pre-push]
#                                          [--pre-push-hooks <csv>]
#                                          [--pre-push-test-cmd <cmd>]
#
# Phases (can combine; each is idempotent on its own):
#   --core    language-agnostic commit-msg + pre-commit via native .git/hooks/
#             (Conventional Commits, block-main, gitleaks)
#   --jsts    Husky + lint-staged + commitlint. Writes .husky/pre-commit,
#             .husky/commit-msg, commitlint.config.js, and lint-staged
#             config inside package.json. Requires node + npm/pnpm/yarn;
#             when missing, emits {"skipped":"jsts-hooks","reason":...}.
#   --python  pre-commit.com + Ruff + commitizen. Writes
#             .pre-commit-config.yaml and optionally runs `pre-commit install`.
#             Requires python3; emits a skipped record otherwise.
#   --go      pre-commit.com + dnephin/pre-commit-golang + golangci-lint.
#   --rust    pre-commit.com + doublify/pre-commit-rust (fmt + clippy).
#   --pre-push   native .git/hooks/pre-push wired up from
#                profile.hooks.pre_push[]. Caller passes --pre-push-hooks
#                <csv> + --pre-push-test-cmd <cmd>; supported well-known
#                IDs: tests, gitleaks-full.
#
# Idempotency markers:
#   - native .git/hooks/*      : "# nyann-managed-hook: <name>"
#   - .husky/<hook>            : "# nyann-managed-husky: <name>"
#   - commitlint.config.js     : "// nyann-managed"
#   - package.json lint-staged : managed with jq, no duplicates

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

_install_hooks_tmp_files=()
# Invoked indirectly via the trap below; shellcheck can't see the
# reference because the function name is single-quoted in the trap arg.
# shellcheck disable=SC2329,SC2317
_install_hooks_cleanup() { rm -f ${_install_hooks_tmp_files[@]+"${_install_hooks_tmp_files[@]}"} 2>/dev/null || true; }
trap '_install_hooks_cleanup' EXIT

target=""
install_core=false
install_jsts=false
install_pre_push=false
pre_push_hooks=""
pre_push_test_cmd=""
install_python=false
install_go=false
install_rust=false
no_install_hook=false
workspace_configs=""
commit_scopes_file=""
core_template_root="${_script_dir}/../templates/hooks"
husky_template_root="${_script_dir}/../templates/husky"
precommit_template_root="${_script_dir}/../templates/pre-commit-configs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          target="${2:-}"; shift 2 ;;
    --target=*)        target="${1#--target=}"; shift ;;
    --core)            install_core=true; shift ;;
    --jsts)            install_jsts=true; shift ;;
    --python)          install_python=true; shift ;;
    --go)              install_go=true; shift ;;
    --rust)            install_rust=true; shift ;;
    --pre-push)        install_pre_push=true; shift ;;
    --pre-push-hooks)  pre_push_hooks="${2:-}"; shift 2 ;;
    --pre-push-hooks=*) pre_push_hooks="${1#--pre-push-hooks=}"; shift ;;
    --pre-push-test-cmd)   pre_push_test_cmd="${2:-}"; shift 2 ;;
    --pre-push-test-cmd=*) pre_push_test_cmd="${1#--pre-push-test-cmd=}"; shift ;;
    --core-template-root)   core_template_root="${2:-}"; shift 2 ;;
    --core-template-root=*) core_template_root="${1#--core-template-root=}"; shift ;;
    --husky-template-root)   husky_template_root="${2:-}"; shift 2 ;;
    --husky-template-root=*) husky_template_root="${1#--husky-template-root=}"; shift ;;
    --precommit-template-root)   precommit_template_root="${2:-}"; shift 2 ;;
    --precommit-template-root=*) precommit_template_root="${1#--precommit-template-root=}"; shift ;;
    --workspace-configs)          workspace_configs="${2:-}"; shift 2 ;;
    --workspace-configs=*)         workspace_configs="${1#--workspace-configs=}"; shift ;;
    --commit-scopes)               commit_scopes_file="${2:-}"; shift 2 ;;
    --commit-scopes=*)             commit_scopes_file="${1#--commit-scopes=}"; shift ;;
    --no-install-hook)       no_install_hook=true; shift ;;
    -h|--help)
      sed -n '3,19p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" ]] || nyann::die "--target is required"
[[ -d "$target/.git" ]] || nyann::die "$target is not a git repo (.git missing)"

if ! $install_core && ! $install_jsts && ! $install_python && ! $install_go && ! $install_rust && ! $install_pre_push; then
  nyann::warn "no install phase selected (--core | --jsts | --python | --go | --rust | --pre-push) — nothing to do"
  exit 0
fi

# --- core phase (native .git/hooks/) -----------------------------------------

install_core_phase() {
  local hooks_dir="$target/.git/hooks"
  if [[ -L "$hooks_dir" ]]; then
    nyann::die "refusing to install hooks via symlinked .git/hooks directory: $hooks_dir"
  fi
  mkdir -p "$hooks_dir"

  local name tmpl dst marker backup
  for name in commit-msg pre-commit; do
    tmpl="$core_template_root/$name"
    dst="$hooks_dir/$name"
    marker="# nyann-managed-hook: $name"

    [[ -f "$tmpl" ]] || nyann::die "template missing: $tmpl"

    # Idempotency: when the marker is already present the hook file was
    # installed by a prior run (and may have user tweaks on top). Leave
    # it alone rather than clobbering those edits on a re-run. Template
    # upgrades ship via explicit PRs, not by re-running install-hooks.
    if [[ -f "$dst" ]] && grep -Fq "$marker" "$dst"; then
      nyann::log "native hook already installed: $dst (marker present, skipping)"
      continue
    fi

    # Hook exists but isn't ours — this used to back-up-then-replace,
    # which silently retired any user customisations beyond block-main.
    # Merge preserves the user's logic; nyann's block-main guard is
    # appended after the user's script in a clearly-marked region.
    if [[ -f "$dst" ]]; then
      # Refuse to follow a pre-existing symlink at $dst or at the
      # backup path. A malicious repo could plant symlinks here before
      # `cp` runs, so `cp` would write through them to an unrelated file.
      if [[ -L "$dst" ]]; then
        nyann::die "refusing to merge into symlinked hook: $dst"
      fi
      backup="${dst}.pre-nyann"
      if [[ -e "$backup" || -L "$backup" ]]; then
        nyann::die "refusing to overwrite existing backup path: $backup"
      fi
      cp "$dst" "$backup"
      # The nyann-managed block MUST run before the user's existing
      # content. The reverse ordering lets a user hook ending in
      # `exit 0` / `exec` bypass gitleaks + block-main entirely. We put
      # nyann first, then `exec` the backed-up user hook so their logic
      # still runs and their exit code is the merged hook's exit code.
      nyann::warn "existing $name hook backed up to $backup; nyann guard runs BEFORE user content"

      # Atomic merge: nyann block first, then exec-chain into user's backup.
      merge_tmp=$(mktemp -t "nyann-hook-${name}.XXXXXX")
      _install_hooks_tmp_files+=("$merge_tmp")
      if ! { printf '#!/usr/bin/env bash\n'; \
             printf '%s\n' "$marker"; \
             printf '# ---- nyann-managed block runs FIRST (gitleaks + block-main) ----\n'; \
             tail -n +2 "$tmpl"; \
             printf '\n# ---- chain to user'\''s preserved hook ----\n'; \
             printf '# If the user hook does not exist, skip cleanly (nyann-only install).\n'; \
             printf 'if [[ -x %q ]]; then\n' "$backup"; \
             printf '  exec %q "$@"\n' "$backup"; \
             printf 'fi\n'; \
           } > "$merge_tmp"; then
        rm -f "$merge_tmp"
        nyann::die "failed to assemble merged hook: $dst"
      fi
      mv "$merge_tmp" "$dst"
      chmod +x "$dst"
      nyann::log "merged native hook: $dst (nyann guard runs first; user hook chained via exec)"
    else
      # Fresh install: write atomically via mktemp + mv so a partial
      # write (disk full, signal) never leaves a half-formed hook.
      fresh_tmp=$(mktemp -t "nyann-hook-${name}.XXXXXX")
      _install_hooks_tmp_files+=("$fresh_tmp")
      if ! { printf '#!/usr/bin/env bash\n'; \
             printf '%s\n' "$marker"; \
             tail -n +2 "$tmpl"; \
           } > "$fresh_tmp"; then
        rm -f "$fresh_tmp"
        nyann::die "failed to write hook: $dst"
      fi
      mv "$fresh_tmp" "$dst"
      chmod +x "$dst"
      nyann::log "installed native hook: $dst"
    fi
  done
}

# --- workspace-aware lint-staged config builder -------------------------------

hook_to_lint_staged_cmd() {
  case "$1" in
    eslint)      echo "eslint --fix" ;;
    prettier)    echo "prettier --write" ;;
    stylelint)   echo "stylelint --fix" ;;
    ruff)        echo "ruff check --fix" ;;
    ruff-format) echo "ruff format" ;;
    *)           return 1 ;;
  esac
}

lang_to_glob() {
  case "$1" in
    typescript|javascript) echo "*.{js,jsx,ts,tsx,mjs,cjs}" ;;
    python)                echo "*.py" ;;
    go)                    echo "*.go" ;;
    rust)                  echo "*.rs" ;;
    *)                     return 1 ;;
  esac
}

build_workspace_lint_staged() {
  local ws_configs="$1"
  local ws_count
  ws_count=$(jq 'length' <<<"$ws_configs")

  local result='{}'
  for (( i=0; i<ws_count; i++ )); do
    local ws
    ws=$(jq -c ".[$i]" <<<"$ws_configs")
    local ws_path ws_lang
    ws_path=$(jq -r '.path' <<<"$ws")
    ws_lang=$(jq -r '.primary_language // "unknown"' <<<"$ws")

    local glob
    glob=$(lang_to_glob "$ws_lang") || continue

    local pre_commit_hooks
    pre_commit_hooks=$(jq -c '.hooks.pre_commit // []' <<<"$ws")
    local cmds='[]'
    local hook_count
    hook_count=$(jq 'length' <<<"$pre_commit_hooks")
    for (( j=0; j<hook_count; j++ )); do
      local hook_name cmd
      hook_name=$(jq -r ".[$j]" <<<"$pre_commit_hooks")
      cmd=$(hook_to_lint_staged_cmd "$hook_name") || continue
      cmds=$(jq --arg c "$cmd" '. + [$c]' <<<"$cmds")
    done

    local cmd_count
    cmd_count=$(jq 'length' <<<"$cmds")
    if (( cmd_count > 0 )); then
      local key="${ws_path}/**/${glob}"
      result=$(jq --arg k "$key" --argjson v "$cmds" '. + {($k): $v}' <<<"$result")
    fi
  done

  # Always include a generic formatting glob for non-code files at root.
  result=$(jq '. + {"*.{json,md,yml,yaml,css,scss}": ["prettier --write"]}' <<<"$result")

  echo "$result"
}

# --- JS/TS phase (husky + commitlint + lint-staged) --------------------------

emit_skipped() {
  # Structured skip-record so the orchestrator can log without ambiguity.
  jq -nc --arg stage "$1" --arg reason "$2" '{skipped:$stage, reason:$reason}'
}

install_jsts_phase() {
  local pkg="$target/package.json"
  if [[ ! -f "$pkg" ]]; then
    nyann::warn "jsts phase skipped: $pkg not found"
    emit_skipped jsts-hooks "package.json missing"
    return 0
  fi

  # Prereq: node must be present — nothing in this phase works without it.
  if ! command -v node >/dev/null 2>&1; then
    nyann::warn "jsts phase skipped: node missing"
    emit_skipped jsts-hooks "node missing"
    return 0
  fi

  # Preferred package manager for messaging; detection mirrors detect-stack.
  local pm=""
  if   [[ -f "$target/pnpm-lock.yaml" ]]; then pm="pnpm"
  elif [[ -f "$target/yarn.lock"       ]]; then pm="yarn"
  elif [[ -f "$target/bun.lockb"       ]]; then pm="bun"
  else                                       pm="npm"
  fi

  # Ensure package.json declares husky + lint-staged dev deps + "prepare"
  # script. We rewrite atomically with jq so formatting stays deterministic.
  #
  # Use mktemp so the temp path can't be pre-symlinked by a malicious
  # repo. Check jq's exit status before `mv` so a filter failure can't
  # leave package.json as an empty/partial file.
  if [[ -L "$pkg" ]]; then
    nyann::die "refusing to rewrite package.json via symlink: $pkg"
  fi
  local tmp_pkg
  tmp_pkg=$(mktemp -t "nyann-pkgjson.XXXXXX") \
    || nyann::die "mktemp failed for package.json rewrite"
  _install_hooks_tmp_files+=("$tmp_pkg")
  # Build lint-staged config: workspace-aware when configs provided.
  local lint_staged_config
  if [[ -n "$workspace_configs" && -f "$workspace_configs" ]]; then
    local ws_json
    ws_json=$(cat "$workspace_configs")
    lint_staged_config=$(build_workspace_lint_staged "$ws_json")
  else
    lint_staged_config='{"*.{js,jsx,ts,tsx,mjs,cjs}":["prettier --write","eslint --fix"],"*.{json,md,yml,yaml,css,scss}":["prettier --write"]}'
  fi

  if ! jq --argjson ls "$lint_staged_config" '
    . as $root
    | (.devDependencies // {}) as $dd
    | .devDependencies = (
        $dd
        | .["husky"]                          //= "^9.1.0"
        | .["lint-staged"]                    //= "^15.2.0"
        | .["@commitlint/cli"]                //= "^19.0.0"
        | .["@commitlint/config-conventional"]//= "^19.0.0"
      )
    | (.scripts // {}) as $s
    | .scripts = ($s | .["prepare"] //= "husky install")
    | ."lint-staged" = ($ls)
  ' "$pkg" > "$tmp_pkg"; then
    rm -f "$tmp_pkg"
    nyann::die "jq failed rewriting $pkg (original left untouched)"
  fi
  if [[ ! -s "$tmp_pkg" ]]; then
    rm -f "$tmp_pkg"
    nyann::die "jq produced empty output for $pkg (original left untouched)"
  fi
  mv "$tmp_pkg" "$pkg"
  nyann::log "package.json updated: husky/lint-staged/commitlint deps + prepare + lint-staged"

  # Write commitlint.config.js only if absent (user config wins).
  # Verify the template exists and write atomically. Previously a
  # missing template would leave a corrupted one-line file because
  # `{ printf; cat; } > file` truncates, prints the first line, then
  # fails on cat under `set -e`.
  local commitlint_cfg="$target/commitlint.config.js"
  local commitlint_tmpl="$husky_template_root/commitlint.config.js"
  if [[ -f "$commitlint_cfg" ]] && ! grep -q 'nyann-managed' "$commitlint_cfg"; then
    nyann::warn "existing commitlint.config.js left alone (not nyann-managed)"
  else
    [[ -f "$commitlint_tmpl" ]] \
      || nyann::die "commitlint template missing: $commitlint_tmpl"
    if [[ -L "$commitlint_cfg" ]]; then
      nyann::die "refusing to rewrite commitlint.config.js via symlink: $commitlint_cfg"
    fi
    local tmp_cfg
    tmp_cfg=$(mktemp -t "nyann-commitlint.XXXXXX") \
      || nyann::die "mktemp failed for commitlint.config.js"
    _install_hooks_tmp_files+=("$tmp_cfg")

    if [[ -n "$commit_scopes_file" && -f "$commit_scopes_file" ]] \
       && jq -e 'length > 0' "$commit_scopes_file" >/dev/null 2>&1; then
      # Generate config with scope-enum from workspace + profile scopes.
      local scope_items
      scope_items=$(jq -r '.[] | @json | "        " + . + ","' "$commit_scopes_file")
      cat > "$tmp_cfg" <<COMMITLINT_EOF
// nyann-managed v1 — remove this line to opt out of regen.
// nyann template v1 — commitlint config (with workspace scopes)
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [
      1,
      'always',
      [
${scope_items}
      ],
    ],
    'type-enum': [
      2,
      'always',
      [
        'feat',
        'fix',
        'chore',
        'docs',
        'refactor',
        'test',
        'perf',
        'ci',
        'build',
        'style',
        'revert',
      ],
    ],
  },
};
COMMITLINT_EOF
    else
      if ! { printf '// nyann-managed v1 — remove this line to opt out of regen.\n'; \
             cat "$commitlint_tmpl"; \
           } > "$tmp_cfg"; then
        rm -f "$tmp_cfg"
        nyann::die "failed to assemble commitlint.config.js"
      fi
    fi
    mv "$tmp_cfg" "$commitlint_cfg"
    nyann::log "wrote $commitlint_cfg"
  fi

  # Write husky hooks. We always create both .husky/_/.gitignore and the
  # hook files so `npx husky install` is a no-op on a fresh clone too.
  local husky_dir="$target/.husky"
  if [[ -L "$husky_dir" ]]; then
    nyann::die "refusing to install hooks via symlinked .husky directory: $husky_dir"
  fi
  mkdir -p "$husky_dir/_"
  if [[ ! -f "$husky_dir/_/.gitignore" ]]; then
    echo "*" > "$husky_dir/_/.gitignore"
  fi

  # Two-phase commit for the husky hook set so a partial install can't
  # leave one hook active and the other missing:
  #   Phase A (assemble) — for every hook: validate template, refuse
  #     symlinks, prepare backups, assemble content into a per-hook
  #     temp file. If anything in this phase fails, NO destination
  #     has been touched yet; the cleanup trap removes the pending
  #     temps. The expensive failure modes (missing template, symlink
  #     at destination, mktemp failure, write failure) all surface
  #     here, before any destination changes.
  #   Phase B (publish) — only after Phase A succeeded for ALL hooks,
  #     mv each temp into place. Phase B writes are tiny and bounded;
  #     a failure here is rare and would at worst leave one hook
  #     half-replaced rather than zero-or-some.
  local name tmpl dst marker backup husky_tmp
  declare -a _staged_hooks=()   # parallel arrays: $name|$tmp|$dst
  declare -a _staged_backups=() # paths we created backups for, for log

  for name in pre-commit commit-msg; do
    tmpl="$husky_template_root/$name"
    dst="$husky_dir/$name"
    marker="# nyann-managed-husky: $name"

    [[ -f "$tmpl" ]] || nyann::die "husky template missing: $tmpl"

    # Refuse to follow a symlink at the destination or the backup path;
    # a hostile repo could otherwise use these to redirect writes.
    if [[ -L "$dst" ]]; then
      nyann::die "refusing to rewrite husky hook via symlink: $dst"
    fi

    if [[ -f "$dst" ]] && ! grep -Fq "$marker" "$dst"; then
      backup="${dst}.pre-nyann"
      if [[ -e "$backup" || -L "$backup" ]]; then
        nyann::die "refusing to overwrite existing husky backup path: $backup"
      fi
      cp "$dst" "$backup"
      _staged_backups+=("$name")
    fi

    husky_tmp=$(mktemp -t "nyann-husky-${name}.XXXXXX") \
      || nyann::die "mktemp failed for husky hook $name"
    _install_hooks_tmp_files+=("$husky_tmp")
    if ! { printf '#!/usr/bin/env sh\n'; \
           printf '%s\n' "$marker"; \
           tail -n +2 "$tmpl"; \
         } > "$husky_tmp"; then
      nyann::die "failed to assemble husky hook: $dst"
    fi
    _staged_hooks+=("${name}|${husky_tmp}|${dst}")
  done

  # Phase B: publish the staged hooks. Iterate in the same order so the
  # log lines mirror the assembly order.
  local entry hook_name hook_tmp hook_dst
  for entry in "${_staged_hooks[@]}"; do
    hook_name="${entry%%|*}"
    hook_tmp="${entry#*|}"; hook_tmp="${hook_tmp%%|*}"
    hook_dst="${entry##*|}"
    mv "$hook_tmp" "$hook_dst"
    chmod +x "$hook_dst"
    nyann::log "installed husky hook: $hook_dst"
  done

  for backup_name in "${_staged_backups[@]}"; do
    nyann::warn "existing .husky/$backup_name was backed up to .husky/${backup_name}.pre-nyann"
  done

  nyann::log "jsts phase ready. Run \`$pm install\` then \`npx husky install\`."
}

# --- Python phase (pre-commit.com + Ruff + commitizen) -----------------------

install_python_phase() {
  if ! command -v python3 >/dev/null 2>&1; then
    nyann::warn "python phase skipped: python3 missing"
    emit_skipped python-hooks "python3 missing"
    return 0
  fi

  # pip is the install vector for pre-commit. We check it but don't fail the
  # phase if pre-commit itself is already available on PATH (user may have
  # installed via uv / pipx).
  if ! command -v pip >/dev/null 2>&1 && ! command -v pip3 >/dev/null 2>&1 \
     && ! command -v pre-commit >/dev/null 2>&1 && ! command -v uv >/dev/null 2>&1; then
    nyann::warn "python phase skipped: no pip/pre-commit/uv found"
    emit_skipped python-hooks "no pip or pre-commit installer available"
    return 0
  fi

  local tmpl="$precommit_template_root/python.yaml"
  local dst="$target/.pre-commit-config.yaml"
  [[ -f "$tmpl" ]] || nyann::die "python template missing: $tmpl"

  if [[ -L "$dst" ]]; then
    nyann::die "refusing to write .pre-commit-config.yaml via symlink: $dst"
  fi

  # Merge hook repos by URL. If the target config is absent, copy template.
  # If present, run a small Python merger that keeps existing entries
  # verbatim and appends any of our repos whose URL isn't already listed.
  if [[ ! -f "$dst" ]]; then
    cp "$tmpl" "$dst"
    nyann::log "wrote $dst"
  else
    python3 - "$dst" "$tmpl" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write("[nyann] PyYAML missing; skipping merge (template copy only)\n")
    sys.exit(0)

dst_path, tmpl_path = sys.argv[1], sys.argv[2]

def load(p):
    with open(p) as f:
        d = yaml.safe_load(f) or {}
    if not isinstance(d, dict):
        sys.stderr.write(f"[nyann] unexpected YAML shape in {p}: root is {type(d).__name__}\n")
        sys.exit(1)
    d.setdefault('repos', [])
    return d

dst = load(dst_path)
tmpl = load(tmpl_path)

def repo_key(r):
    if r.get('repo') == 'local':
        ids = tuple(sorted((h.get('id') for h in r.get('hooks', []) if h.get('id'))))
        return ('local', ids)
    return ('remote', r.get('repo'))

existing = {repo_key(r): r for r in dst['repos']}
added = 0
for r in tmpl['repos']:
    k = repo_key(r)
    if k in existing:
        continue
    dst['repos'].append(r)
    existing[k] = r
    added += 1

if added:
    with open(dst_path, 'w') as f:
        yaml.safe_dump(dst, f, sort_keys=False)
    print(f"[nyann] merged {added} nyann repo(s) into .pre-commit-config.yaml")
else:
    print("[nyann] .pre-commit-config.yaml already has all nyann repos; no change")
PY
    nyann::log "merged nyann hooks into $dst"
  fi

  # Install the hook into .git/hooks so commits actually trigger pre-commit.
  # Guarded: prefer existing pre-commit on PATH; fall back to uvx.
  if $no_install_hook; then
    nyann::log "--no-install-hook set; skipping pre-commit install"
    return 0
  fi

  local pre_commit_cmd=()
  if command -v pre-commit >/dev/null 2>&1; then
    pre_commit_cmd=(pre-commit)
  elif command -v uvx >/dev/null 2>&1; then
    pre_commit_cmd=(uvx pre-commit)
  else
    nyann::warn "pre-commit not on PATH; install with 'pip install pre-commit' then run 'pre-commit install'"
    return 0
  fi

  if ( cd "$target" && "${pre_commit_cmd[@]}" install --install-hooks >/dev/null 2>&1 ); then
    nyann::log "pre-commit install completed"
  else
    nyann::warn "pre-commit install failed; run it manually in $target"
  fi
}

# --- Go phase (pre-commit.com + gofmt + go vet + golangci-lint) --------------

install_go_phase() {
  if ! command -v go >/dev/null 2>&1; then
    nyann::warn "go phase skipped: go binary missing"
    emit_skipped go-hooks "go missing"
    return 0
  fi
  install_precommit_from_template "$precommit_template_root/go.yaml" "go-hooks"
}

# --- Rust phase (pre-commit.com + rustfmt + clippy) --------------------------

install_rust_phase() {
  if ! command -v cargo >/dev/null 2>&1; then
    nyann::warn "rust phase skipped: cargo missing"
    emit_skipped rust-hooks "cargo missing"
    return 0
  fi
  install_precommit_from_template "$precommit_template_root/rust.yaml" "rust-hooks"
}

# --- shared pre-commit.com install helper ------------------------------------
# Writes (or merges into) target/.pre-commit-config.yaml from the given
# template file. Merge logic is identical to install_python_phase — key by
# repo URL so the user's pinned revs win.

install_precommit_from_template() {
  local tmpl="$1"
  local stage="${2:-hooks}"
  local dst="$target/.pre-commit-config.yaml"

  [[ -f "$tmpl" ]] || nyann::die "template missing: $tmpl"

  if [[ -L "$dst" ]]; then
    nyann::die "refusing to write .pre-commit-config.yaml via symlink: $dst"
  fi

  # python3 is the only hard requirement for the merge path. If missing,
  # fall back to "copy template if no existing config" and warn.
  if command -v python3 >/dev/null 2>&1 && [[ -f "$dst" ]]; then
    python3 - "$dst" "$tmpl" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write("[nyann] PyYAML missing; skipping merge (template copy only)\n")
    sys.exit(0)

dst_path, tmpl_path = sys.argv[1], sys.argv[2]

def load(p):
    with open(p) as f:
        d = yaml.safe_load(f) or {}
    if not isinstance(d, dict):
        sys.stderr.write(f"[nyann] unexpected YAML shape in {p}: root is {type(d).__name__}\n")
        sys.exit(1)
    d.setdefault('repos', [])
    return d

dst = load(dst_path)
tmpl = load(tmpl_path)

def repo_key(r):
    if r.get('repo') == 'local':
        ids = tuple(sorted((h.get('id') for h in r.get('hooks', []) if h.get('id'))))
        return ('local', ids)
    return ('remote', r.get('repo'))

existing = {repo_key(r): r for r in dst['repos']}
added = 0
for r in tmpl['repos']:
    k = repo_key(r)
    if k in existing:
        continue
    dst['repos'].append(r)
    existing[k] = r
    added += 1

if added:
    with open(dst_path, 'w') as f:
        yaml.safe_dump(dst, f, sort_keys=False)
    print(f"[nyann] merged {added} nyann repo(s) into .pre-commit-config.yaml")
else:
    print("[nyann] .pre-commit-config.yaml already has all nyann repos; no change")
PY
    nyann::log "merged nyann hooks into $dst"
  elif [[ ! -f "$dst" ]]; then
    cp "$tmpl" "$dst"
    nyann::log "wrote $dst"
  fi

  if $no_install_hook; then
    nyann::log "--no-install-hook set; skipping pre-commit install ($stage)"
    return 0
  fi

  local pre_commit_cmd=()
  if command -v pre-commit >/dev/null 2>&1; then
    pre_commit_cmd=(pre-commit)
  elif command -v uvx >/dev/null 2>&1; then
    pre_commit_cmd=(uvx pre-commit)
  else
    nyann::warn "pre-commit not on PATH; install with 'pip install pre-commit'"
    return 0
  fi

  if ( cd "$target" && "${pre_commit_cmd[@]}" install --install-hooks >/dev/null 2>&1 ); then
    nyann::log "pre-commit install completed ($stage)"
  else
    nyann::warn "pre-commit install failed; run it manually in $target"
  fi
}

# --- pre-push phase (native .git/hooks/pre-push) ----------------------------
# Wires up profile.hooks.pre_push[]. Caller (typically bootstrap.sh)
# passes --pre-push-hooks <csv> from the profile + --pre-push-test-cmd
# <cmd> derived from the detected stack. Marker-bounded so the hook
# survives re-installs without clobbering user customisations.
#
# Supported well-known IDs (others log a warn and are skipped):
#   tests        run the stack-detected test command (npm test / pytest /
#                go test ./... / cargo test). Caller supplies via
#                --pre-push-test-cmd; absent + tests requested = warn.
#   gitleaks-full  run `gitleaks detect --no-git --redact` over the
#                  full working tree. Slower than pre-commit's staged-
#                  scan but catches secrets a partial commit might
#                  smuggle through.

install_pre_push_phase() {
  local hooks_dir="$target/.git/hooks"
  if [[ -L "$hooks_dir" ]]; then
    nyann::die "refusing to install hooks via symlinked .git/hooks directory: $hooks_dir"
  fi
  mkdir -p "$hooks_dir"

  if [[ -z "$pre_push_hooks" ]]; then
    nyann::log "pre-push: no hooks declared in profile.hooks.pre_push[] — skipping"
    return 0
  fi

  local dst="$hooks_dir/pre-push"
  # BEGIN/END marker pair gives the regenerator a precise boundary to
  # rewrite, so user content appended after END survives re-installs
  # byte-for-byte. A single-marker form can't distinguish where
  # nyann's block ends, so user edits get dropped on re-install.
  local marker_begin="# nyann-managed-hook: pre-push BEGIN"
  local marker_end="# nyann-managed-hook: pre-push END"
  # Compatibility marker (still grepped by all tests + tooling).
  local marker_compat="# nyann-managed-hook: pre-push"

  # Idempotency:
  #   - Existing nyann hook (BEGIN+END markers): preserve everything
  #     after END verbatim, rebuild the block between the markers.
  #   - Existing nyann hook (legacy single-marker, no BEGIN/END):
  #     can't safely preserve user edits — the boundary is ambiguous.
  #     Rebuild from scratch and emit a warn so the user knows.
  #   - Existing user hook (no marker at all): back up to .pre-nyann
  #     and exec-chain AFTER the nyann gates so user logic still runs.
  local backup=""
  local user_tail=""
  if [[ -f "$dst" ]]; then
    if [[ -L "$dst" ]]; then
      nyann::die "refusing to merge into symlinked hook: $dst"
    fi
    if grep -Fq "$marker_begin" "$dst" && grep -Fq "$marker_end" "$dst"; then
      # Lift everything after the END marker line. awk's exact-string
      # comparison handles arbitrary user content (no regex pitfalls).
      user_tail=$(awk -v end="$marker_end" '
        found { print; next }
        $0 == end { found = 1 }
      ' "$dst")
    elif grep -Fq "$marker_compat" "$dst"; then
      nyann::warn "pre-push hook installed by an older nyann (no BEGIN/END markers); re-installing fresh — manual content between the marker and 'exit 0' will be lost. Back up first if needed."
    else
      backup="${dst}.pre-nyann"
      if [[ -e "$backup" || -L "$backup" ]]; then
        nyann::die "refusing to overwrite existing backup path: $backup"
      fi
      cp "$dst" "$backup"
      nyann::warn "existing pre-push hook backed up to $backup; nyann gates run BEFORE user content"
    fi
  fi

  # Build the hook body. Each pre_push entry maps to a `_run_<id>`
  # function call. Unknown IDs warn at install time AND emit a runtime
  # warn so the user can see them in CI logs.
  local pp_tmp
  pp_tmp=$(mktemp -t "nyann-prepush.XXXXXX")
  _install_hooks_tmp_files+=("$pp_tmp")

  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$marker_begin"
    printf '# Generated by bin/install-hooks.sh --pre-push.\n'
    printf '# Reads commit range from stdin per the git pre-push contract.\n'
    printf '# Exits non-zero on first hook failure so the push is aborted.\n'
    printf '# To add your own pre-push checks, append them BELOW the END\n'
    printf '# marker — content after the END marker survives re-installs.\n'
    printf 'set -e\n\n'

    # Read the pushed-ref-spec stdin once so multiple sub-checks can
    # introspect (kept as a shell array for future hooks that need
    # commit-range awareness; current hooks scan the working tree).
    # Single-quoted because the $(...) and "$1" must reach the
    # generated hook verbatim, not be expanded here.
    # shellcheck disable=SC2016
    printf '_pushed=$(cat || true)\n\n'
    # shellcheck disable=SC2016
    printf 'fail() { printf "[nyann pre-push] %%s\\n" "$1" >&2; exit 1; }\n\n'

    # Per-hook function definitions. Even if the user only requests
    # one, all known functions are defined so future re-runs can
    # toggle between them without re-installing.
    if [[ -n "$pre_push_test_cmd" ]]; then
      # shellcheck disable=SC2016
      printf '_run_tests() {\n'
      printf '  printf "[nyann pre-push] running tests: %%s\\n" %q >&2\n' "$pre_push_test_cmd"
      printf '  %s || fail "tests failed"\n' "$pre_push_test_cmd"
      printf '}\n\n'
    else
      printf '_run_tests() {\n'
      printf '  fail "tests pre-push hook requested but no --pre-push-test-cmd was supplied at install time"\n'
      printf '}\n\n'
    fi

    printf '_run_gitleaks_full() {\n'
    printf '  if ! command -v gitleaks >/dev/null 2>&1; then\n'
    printf '    printf "[nyann pre-push] gitleaks not on PATH; skipping full-tree scan\\n" >&2\n'
    printf '    return 0\n'
    printf '  fi\n'
    printf '  gitleaks detect --no-git --redact || fail "gitleaks detected secrets"\n'
    printf '}\n\n'

    printf '# --- dispatch ---\n'
    local id
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      case "$id" in
        tests)         printf '_run_tests\n' ;;
        gitleaks-full) printf '_run_gitleaks_full\n' ;;
        *)
          nyann::warn "pre-push: unknown hook id '$id' — skipped at install time"
          printf '# unknown hook id %q — skipped at install time\n' "$id"
          ;;
      esac
    done < <(printf '%s\n' "$pre_push_hooks" | tr ',' '\n')

    if [[ -n "$backup" ]]; then
      printf '\n# --- chain to user'\''s preserved pre-push ---\n'
      printf 'if [[ -x %q ]]; then\n' "$backup"
      # Single-quoted "$@" and "$_pushed" must reach the generated
      # hook verbatim — they expand at hook-runtime, not install-time.
      # shellcheck disable=SC2016
      printf '  exec %q "$@" <<<"$_pushed"\n' "$backup"
      printf 'fi\n'
    fi

    printf '\n%s\n' "$marker_end"

    # Replay user content captured before the rebuild. Skip the leading
    # blank line that's almost always present (cosmetic — user content
    # was originally written after a printf '\n%s\n' separator).
    if [[ -n "$user_tail" ]]; then
      printf '%s\n' "$user_tail"
    fi
  } > "$pp_tmp"

  mv "$pp_tmp" "$dst"
  chmod +x "$dst"
  nyann::log "installed pre-push hook: $dst (hooks: $pre_push_hooks)"
}

# --- dispatch -----------------------------------------------------------------

if $install_core;     then install_core_phase;     fi
if $install_jsts;     then install_jsts_phase;     fi
if $install_python;   then install_python_phase;   fi
if $install_go;       then install_go_phase;       fi
if $install_rust;     then install_rust_phase;     fi
if $install_pre_push; then install_pre_push_phase; fi

exit 0
