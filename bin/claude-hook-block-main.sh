#!/usr/bin/env bash
# claude-hook-block-main.sh — Claude Code PreToolUse hook.
#
# Wired in hooks/hooks.json against `Bash` invocations whose args look
# like `git commit ...` or `git push ...`. Blocks (exit 2) when the
# current branch is main/master, unless the command carries
# `--no-verify` (documented user escape hatch).
#
# Input — Claude Code passes tool invocation info via a JSON payload on
# stdin. For portability we parse either:
#   1. A JSON object with {"tool_input":{"command":"..."}} (the current
#      Claude Code PreToolUse contract), or
#   2. A raw command string as the first positional arg (older contract).
# Any other shape passes through (exit 0) rather than blocking — the
# matcher already narrowed things, and the default for unexpected input
# should be "let the user proceed".

set -e
set -u
set -o pipefail

# --- parse command -----------------------------------------------------------

cmd=""

if [[ -n "${1:-}" ]]; then
  cmd="$1"
fi

if [[ -z "$cmd" ]] && [[ ! -t 0 ]]; then
  # Read stdin; tolerate non-JSON gracefully.
  stdin_blob="$(cat || true)"
  # Only accept the JSON-shaped contract. If jq can't parse or the
  # command field is absent, treat it as "nothing to inspect" rather
  # than falling back to raw stdin as $cmd — arbitrary non-JSON input
  # containing the substring "git commit" would otherwise trigger a
  # false block.
  if [[ -n "$stdin_blob" ]] && command -v jq >/dev/null 2>&1; then
    parsed=$(jq -r '.tool_input.command // .command // empty' <<<"$stdin_blob" 2>/dev/null || true)
    [[ -n "$parsed" ]] && cmd="$parsed"
  fi
fi

# Nothing to inspect → pass through.
[[ -z "$cmd" ]] && exit 0

# --- parse git invocations properly ------------------------------------------
# Tokenising via Python's shlex (rather than a regex) buys two things:
#   * Global git options (`git -C <dir>`, `git -c user.email=x commit`)
#     are recognised so we branch-check the right repo and don't let
#     `git -C /path commit` slip past.
#   * `--no-verify` is matched positionally to its subcommand, so a
#     decoy like `echo --no-verify; git commit` no longer fools the
#     hook.
# When python isn't on PATH the script falls back to a narrower grep
# check below.

parse_and_check() {
  # Emits either:
  #   PASS
  #   BLOCK <subcommand> <repo_dir_or_empty>
  # on stdout; caller acts on the first line.
  CMD="$1" python3 - <<'PY'
import os, re, shlex, sys

cmd = os.environ.get("CMD", "")
if not cmd:
    print("PASS"); sys.exit(0)

# Pad shell operators with whitespace so shlex keeps them as their own
# tokens. `echo x; git commit` (no space before `;`) would otherwise
# tokenise as `['echo', 'x;', 'git', 'commit']` — the semicolon gets
# glued to the previous word. POSIX shlex doesn't know about shell
# operators, so we massage the input beforehand. Order matters: the
# double-char operators must be replaced first.
for op in ("&&", "||"):
    cmd = cmd.replace(op, f" {op} ")
# Single-char operators: `;`, `|`, `&` (but `&&` already replaced).
cmd = re.sub(r"(?<![&|])([;|&])(?![&|])", r" \1 ", cmd)

try:
    raw_tokens = shlex.split(cmd, posix=True)
except ValueError:
    # Malformed quoting → don't pretend to understand. Err on the
    # side of blocking only when we see an unambiguous positive.
    print("PASS"); sys.exit(0)

operators = {"&&", "||", ";", "|", "&"}
clauses = [[]]
for tok in raw_tokens:
    if tok in operators:
        clauses.append([])
    else:
        clauses[-1].append(tok)

# Git global options that take a value. `-C` and `--git-dir` matter
# because they re-target the repo we need to branch-check; the others
# just need to be skipped over to find the subcommand.
flags_with_arg = {"-C", "-c", "--git-dir", "--work-tree",
                  "--namespace", "--super-prefix",
                  "--exec-path", "--config-env"}

def strip_eq(tok, flag):
    # Return the value after `flag=` if the token is `flag=value`.
    if tok.startswith(flag + "="):
        return tok[len(flag) + 1:]
    return None

for clause in clauses:
    if not clause or clause[0] != "git":
        continue
    i = 1
    repo_dir = ""
    git_dir = ""
    work_tree = ""
    while i < len(clause):
        t = clause[i]
        # `-C <dir>` — set branch-check target.
        if t == "-C" and i + 1 < len(clause):
            repo_dir = clause[i + 1]; i += 2; continue
        # `--git-dir=<path>` / `--git-dir <path>`.
        v = strip_eq(t, "--git-dir")
        if v is not None:
            git_dir = v; i += 1; continue
        if t == "--git-dir" and i + 1 < len(clause):
            git_dir = clause[i + 1]; i += 2; continue
        # `--work-tree=<path>` / `--work-tree <path>`.
        v = strip_eq(t, "--work-tree")
        if v is not None:
            work_tree = v; i += 1; continue
        if t == "--work-tree" and i + 1 < len(clause):
            work_tree = clause[i + 1]; i += 2; continue
        # Other flags-with-arg: consume value-carrying or `=value` forms.
        if any(strip_eq(t, f) is not None for f in flags_with_arg):
            i += 1; continue
        if t in flags_with_arg:
            i += 2; continue
        # Other leading `-` tokens: skip (flags-without-arg).
        if t.startswith("-"):
            i += 1; continue
        break
    if i >= len(clause):
        continue
    sub = clause[i]
    if sub not in ("commit", "push"):
        continue
    # `--no-verify` only honours the escape hatch when positional to
    # this subcommand, not when it appeared in an unrelated clause.
    rest = clause[i + 1:]
    if "--no-verify" in rest or any(strip_eq(a, "--no-verify") is not None for a in rest):
        continue
    # Prefer -C target, then --git-dir, then --work-tree.
    branch_dir = repo_dir or work_tree or ""
    if not branch_dir and git_dir:
        # `.git` → its parent directory is the work tree by default.
        branch_dir = git_dir.rstrip("/")
        if branch_dir.endswith("/.git"):
            branch_dir = branch_dir[:-5]
        elif os.path.basename(branch_dir) == ".git":
            branch_dir = os.path.dirname(branch_dir)
    # Emit JSON so callers can parse fields without worrying about
    # spaces in $branch_dir — awk tokenises on whitespace and would
    # truncate paths containing spaces (common on macOS).
    import json as _json
    print(_json.dumps({"decision": "BLOCK", "sub": sub, "branch_dir": branch_dir}))
    sys.exit(0)

print('{"decision":"PASS"}')
PY
}

parse_result=""
if command -v python3 >/dev/null 2>&1; then
  parse_result=$(parse_and_check "$cmd" 2>/dev/null || true)
fi

if [[ -z "$parse_result" ]]; then
  # Fallback to a less accurate grep-based check when python is
  # unreachable. Coverage is narrower (no `git -C` / `--git-dir`
  # awareness) but the hook stays usable on minimal environments.
  if ! grep -Eq '(^|[[:space:]\|&;])git[[:space:]]+(commit|push)\b' <<<"$cmd"; then
    exit 0
  fi
  if grep -Eq '(^|[[:space:]])--no-verify\b' <<<"$cmd"; then
    exit 0
  fi
  # Fallback also emits JSON so the parsing below doesn't care which
  # path produced the result.
  sub_fallback=$(grep -Eo 'commit|push' <<<"$cmd" | head -1)
  parse_result=$(jq -nc --arg sub "$sub_fallback" '{decision:"BLOCK", sub:$sub, branch_dir:""}')
fi

# Parse JSON from the python block (or fallback above) with jq so
# paths containing spaces survive.
decision=$(jq -r '.decision // "PASS"' <<<"$parse_result" 2>/dev/null || echo PASS)
if [[ "$decision" != "BLOCK" ]]; then
  exit 0
fi
subcmd=$(jq -r '.sub // ""' <<<"$parse_result")
repo_dir=$(jq -r '.branch_dir // ""' <<<"$parse_result")

# --- branch check ------------------------------------------------------------
# If -C <dir> was specified, resolve the branch there; otherwise from cwd.
if [[ -n "$repo_dir" ]]; then
  branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
else
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
fi

case "$branch" in
  main|master)
    # Block with exit 2 so Claude Code surfaces the message as a hard
    # failure. Per Claude Code hook contract, stderr is shown to the user.
    # Backticks here are literal markdown for the user-facing message —
    # not shell command substitution. Single-quotes are intentional.
    # shellcheck disable=SC2016
    {
      printf '[nyann] Blocked: direct %s on branch %q.\n' "$subcmd" "$branch"
      printf '\n'
      printf '  Create a feature branch first:\n'
      printf '    /nyann:branch feature <slug>\n'
      printf '  (or run `bin/new-branch.sh --purpose feature --slug <slug> --checkout`\n'
      printf '   if you prefer the script directly).\n'
      printf '\n'
      printf '  Emergency bypass: re-run with `--no-verify` appended.\n'
    } >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
