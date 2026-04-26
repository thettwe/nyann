#!/usr/bin/env bats
# Skill ↔ script invocation contract.
# Every `bin/<script>.sh ... --<flag>` snippet inside a SKILL.md (or
# its references/) must reference a flag the script actually accepts.
# Without this lock, a flag rename in bin/ silently strands the docs
# and Claude follows the dead instruction on first invocation.
#
# Attribution rule: each `--flag` is attributed to the nearest
# `bin/<name>.sh` token to its LEFT on the same line. Lines like
# `pre-commit install --install-hooks runs from bin/install-hooks.sh
# --python` correctly attribute --python to install-hooks.sh and
# leave --install-hooks unattributed (it belongs to pre-commit).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "every flag mentioned in skill docs exists in the target bin script" {
  cd "$REPO_ROOT"

  # Use python for the parsing — bash regex on the line buffer is
  # imprecise enough to produce false positives (different scripts +
  # flags interleaved on the same line). Python keeps the
  # nearest-left-script attribution clean.
  problems=$(python3 - <<'PY'
import os, re, sys

repo = os.environ.get("REPO_ROOT", os.getcwd())
out_lines = []

skill_files = []
for root, dirs, files in os.walk(os.path.join(repo, "skills")):
    for f in files:
        if f.endswith((".md",)):
            skill_files.append(os.path.join(root, f))

flag_re   = re.compile(r"--[a-z][a-z0-9-]*")
script_re = re.compile(r"bin/([a-z][a-z0-9-]*)\.sh")

# Flags that nearly every script implements and that we'd skip from
# the lock check anyway. Keeping them in scope just produces noise.
universal = set()  # empty: we want to verify --json/--dry-run/--force/--yes too

for path in skill_files:
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            # Walk every --flag occurrence and attribute it to the
            # nearest bin/<name>.sh to its left on the same line.
            for fm in flag_re.finditer(line):
                flag = fm.group(0)
                if flag in universal:
                    continue
                # Find the latest bin/<name>.sh before this flag's start.
                left = line[:fm.start()]
                last_script = None
                for sm in script_re.finditer(left):
                    last_script = sm.group(0)
                if not last_script:
                    continue
                script_path = os.path.join(repo, last_script)
                if not os.path.isfile(script_path):
                    out_lines.append(f"{path}:{lineno}: references missing {last_script}")
                    continue
                # Look for a case-arm matching this flag.
                with open(script_path) as sh:
                    body = sh.read()
                pattern = re.compile(r"^\s*" + re.escape(flag) + r"(\)|=\*\))", re.M)
                if not pattern.search(body):
                    rel = os.path.relpath(path, repo)
                    out_lines.append(f"{rel}:{lineno}: {last_script} does not accept {flag}")

print("\n".join(out_lines))
PY
)
  if [[ -n "$problems" ]]; then
    echo "Found skill→script flag drift:" >&2
    echo "$problems" >&2
    return 1
  fi
}
