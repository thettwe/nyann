#!/usr/bin/env bash
# check-prereqs.sh — survey the machine and report what nyann features
# are usable right now.
#
# Usage: check-prereqs.sh [--json]
#
# Output: a human-readable table by default, JSON with --json.
# Never mutates anything. Classifies prereqs as hard (nyann can't run
# without them) vs soft (graceful skip with a clear reason).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

json_out=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)    json_out=true; shift ;;
    -h|--help) sed -n '3,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

# --- probes ------------------------------------------------------------------
# Each check outputs one line to the probes array: kind | tool | status |
# version | hint.
#   kind    hard / soft
#   tool    name
#   status  ok / missing
#   version first-line of --version, or "" when missing
#   hint    install command or reason when missing

probes=()

tool_version() {
  case "$1" in
    git)         git --version 2>&1 ;;
    jq)          jq --version 2>&1 ;;
    bash)        bash --version 2>&1 | head -1 ;;
    python3)     python3 --version 2>&1 ;;
    node)        node --version 2>&1 ;;
    pnpm)        pnpm --version 2>&1 ;;
    npm)         npm --version 2>&1 ;;
    go)          go version 2>&1 ;;
    cargo)       cargo --version 2>&1 ;;
    gh)          gh --version 2>&1 | head -1 ;;
    gitleaks)    gitleaks version 2>&1 ;;
    pre-commit)  pre-commit --version 2>&1 ;;
    uv)          uv --version 2>&1 ;;
    shellcheck)  shellcheck --version 2>&1 | head -2 | tail -1 ;;
    bats)        bats --version 2>&1 ;;
    *)           echo "unknown" ;;
  esac
}

probe() {
  local kind="$1" tool="$2" hint="$3"
  if command -v "$tool" >/dev/null 2>&1; then
    local ver=""
    ver=$(tool_version "$tool" | head -1 | tr -d '\r')
    probes+=("$kind|$tool|ok|$ver|")
  else
    probes+=("$kind|$tool|missing||$hint")
  fi
}

# Hard requirements — nyann's main path dies without these.
probe hard git        "brew install git / apt install git-all"
probe hard jq         "brew install jq / apt install jq"
probe hard bash       "(should be present on any Unix-y machine)"

# Soft requirements — stack-specific or nice-to-have. Graceful skip.
probe soft python3    "brew install python / apt install python3"
probe soft node       "brew install node / apt install nodejs (needed for --jsts hook install)"
probe soft pnpm       "brew install pnpm / npm i -g pnpm (JS/TS with pnpm lockfile)"
probe soft npm        "ships with node (JS/TS fallback)"
probe soft go         "brew install go / apt install golang-go (--go hook install)"
probe soft cargo      "https://rustup.rs (--rust hook install)"
probe soft gh         "brew install gh / apt install gh (branch protection)"
probe soft gitleaks   "brew install gitleaks (pre-commit secret scan)"
probe soft pre-commit "brew install pre-commit / pip install pre-commit (Python hook install)"
probe soft uv         "brew install uv (schema validation via uvx check-jsonschema)"
probe soft shellcheck "brew install shellcheck (dev-only: tests/lint.sh)"
probe soft bats       "brew install bats-core (dev-only: bats tests/bats)"

# PyYAML: soft, but surface separately since it gates .pre-commit-config
# merge + MCP routing detection details.
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  pyyaml_ver=$(python3 -c "import yaml; print(yaml.__version__)" 2>/dev/null)
  probes+=("soft|python3-PyYAML|ok|$pyyaml_ver|")
else
  probes+=("soft|python3-PyYAML|missing||python3 -m pip install PyYAML")
fi

# check-jsonschema (native binary or via uvx).
if command -v check-jsonschema >/dev/null 2>&1; then
  probes+=("soft|check-jsonschema|ok|$(check-jsonschema --version 2>&1 | head -1)|")
elif command -v uvx >/dev/null 2>&1; then
  probes+=("soft|check-jsonschema|ok (via uvx)||")
else
  probes+=("soft|check-jsonschema|missing||brew install uv (preferred) or pip install check-jsonschema")
fi

# --- emit --------------------------------------------------------------------

if $json_out; then
  jq -n --args '{
    prereqs: ($ARGS.positional | map(
      split("|") | {
        kind: .[0],
        tool: .[1],
        status: .[2],
        version: (.[3] | if . == "" then null else . end),
        hint: (.[4] | if . == "" then null else . end)
      }
    ))
  }' "${probes[@]}"
  exit 0
fi

# Pretty table. Stderr would be weird for a "check" tool; write to stdout
# so users can pipe to less / grep.

print_row() {
  local kind="$1" tool="$2" status="$3" version="$4" hint="$5"
  local status_col="$status"
  case "$status" in
    ok*) status_col="✓ $status" ;;
    missing) status_col="✗ missing" ;;
  esac
  printf '  %-6s %-20s %-14s %s\n' "$kind" "$tool" "$status_col" "${version:-$hint}"
}

printf '\nnyann prereq check\n\n'
printf '  %-6s %-20s %-14s %s\n' KIND TOOL STATUS 'VERSION / HINT'
printf '  %-6s %-20s %-14s %s\n' '----' '----' '------' '--------------'
for p in "${probes[@]}"; do
  IFS='|' read -r kind tool status version hint <<<"$p"
  print_row "$kind" "$tool" "$status" "$version" "$hint"
done

# Verdict — any missing hard prereq blocks nyann from running.
missing_hard=0
for p in "${probes[@]}"; do
  IFS='|' read -r kind _tool status _v _h <<<"$p"
  if [[ "$kind" == "hard" && "$status" == "missing" ]]; then
    missing_hard=$((missing_hard + 1))
  fi
done

printf '\n'
if (( missing_hard > 0 )); then
  printf '[nyann] %d hard prerequisite(s) missing — nyann will not run.\n' "$missing_hard"
  exit 1
fi
printf '[nyann] all hard prerequisites satisfied.\n'
printf '[nyann] soft prereqs marked "missing" disable specific features but never crash nyann.\n'
