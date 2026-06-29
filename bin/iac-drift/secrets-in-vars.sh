#!/usr/bin/env bash
# Detector: committed secrets in IaC var files (severity CRITICAL).
#
# SECURITY-CRITICAL design. False positives train users to ignore the tool,
# which is worse than a miss here because iac-drift PAIRS WITH (does not
# replace) gitleaks/trufflehog. The whole detector therefore DEFAULTS TO NOT
# FLAGGING on any uncertainty. It only fires when ALL of these hold:
#
#   (a) the value matches a KNOWN credential shape:
#         - AWS access key id:  (AKIA|ASIA)[0-9A-Z]{16}
#         - PEM private key:    -----BEGIN ... PRIVATE KEY-----
#         - Slack token:        xox[baprs]-...
#         - GitHub token:       ghp_/gho_/ghu_/ghs_/ghr_ + 36 base62
#         - keyed high-entropy: assignment to a key named like
#           password|secret|token|api_key|access_key|... whose value is a
#           long, mixed, non-placeholder, non-var-ref string.
#   (b) the file is COMMITTED — tracked by git AND not gitignored. A
#       gitignored or untracked-only file is NEVER flagged.
#   (c) the line/value is not suppressed by `# drift-ignore` /
#       `<!-- drift-ignore -->` and the value is not listed in
#       .nyann/secret-allowlist.
#
# Found values are REDACTED in the emitted finding (never echo the secret).
#
# Usage: secrets-in-vars.sh --target <dir> --file <relpath>
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

# Only scan files that are plausibly var/config files. Anything else
# (a .tf with HCL logic, a Chart.yaml) is out of scope for this detector —
# narrow scope is a deliberate false-positive control.
base="$(basename "$file")"
case "$file" in
  *.tfvars|*.tfvars.json) ;;
  *) case "$base" in
       Pulumi.*.yaml|Pulumi.*.yml) ;;
       *)
         # Ansible vars/vault: group_vars/host_vars/* (at any depth, incl.
         # repo root) or *vault* files.
         case "$file" in
           group_vars/*|host_vars/*|*/group_vars/*|*/host_vars/*) ;;
           *vault*.yml|*vault*.yaml|*/vault*) ;;
           *) exit 0 ;;
         esac
         ;;
     esac
     ;;
esac

# (b) Committed-only gate. This is the load-bearing safety property:
#   - Inside a git repo, the file MUST be tracked (git ls-files) AND MUST NOT
#     be gitignored (git check-ignore). Either condition failing → silent
#     exit, so we never flag a developer's local-only secrets file that is
#     correctly gitignored, nor an untracked scratch file.
#   - Outside a git repo (e.g. a non-git fixture), there is no "committed"
#     concept; we fall back to scanning so the heuristics remain testable,
#     but a real repo always takes the strict path.
if git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
  # Tracked? (committed or staged into the index)
  if ! git -C "$target" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    exit 0
  fi
  # Gitignored? exit 0 from check-ignore means IGNORED → never flag.
  if git -C "$target" check-ignore -q -- "$file" >/dev/null 2>&1; then
    exit 0
  fi
fi

# (c) Allowlist load. .nyann/secret-allowlist holds one literal token per
# line (blank lines and `#` comments ignored). A value matching any entry is
# never flagged — the user has vetted it (e.g. a documented dummy key).
declare -a allowlist=()
allow_file="$target/.nyann/secret-allowlist"
if [[ -f "$allow_file" ]]; then
  while IFS= read -r al || [[ -n "$al" ]]; do
    al="${al%$'\r'}"
    al="${al#"${al%%[![:space:]]*}"}"   # ltrim
    [[ -z "$al" || "$al" == \#* ]] && continue
    allowlist+=("$al")
  done < "$allow_file"
fi
is_allowlisted() {
  local v="$1" a
  (( ${#allowlist[@]} == 0 )) && return 1
  for a in "${allowlist[@]}"; do
    [[ "$v" == "$a" ]] && return 0
  done
  return 1
}

# Strip surrounding quotes / trailing comma+space from an extracted value.
clean_value() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"          # ltrim
  v="${v%"${v##*[![:space:]]}"}"          # rtrim
  v="${v%,}"                              # trailing comma (json/hcl)
  # Surrounding matched quotes.
  if [[ "$v" == \"*\" ]]; then v="${v#\"}"; v="${v%\"}"; fi
  if [[ "$v" == \'*\' ]]; then v="${v#\'}"; v="${v%\'}"; fi
  printf '%s' "$v"
}

# Redact a value for safe display: keep first 4 chars, mask the rest.
redact() {
  local v="$1" n=${#1}
  if (( n <= 4 )); then printf '****'; return; fi
  printf '%s%s' "${v:0:4}" "$(printf '%*s' $((n - 4)) '' | tr ' ' '*')"
}

emit() {
  # emit <line> <message> <redacted-current> <hint>
  local line="$1" message="$2" current="$3" hint="$4"
  jq -n --arg kind "secret-in-vars" \
        --arg file "$file" \
        --argjson line "$line" \
        --arg severity "critical" \
        --arg message "$message" \
        --arg current "$current" \
        --arg hint "$hint" \
        '{kind:$kind, file:$file, line:$line, severity:$severity, message:$message, current:$current, fix_hint:$hint}'
}

pair_hint="rotate the credential, move it out of version control (use a secret manager / encrypted vars), and pair iac-drift with gitleaks for full coverage"

# Is a value high-entropy enough to be a real secret? Conservative: require
# length >= 20, a mix of letters AND digits, and at least one of those being
# present in quantity. Used ONLY when the value is assigned to a secret-named
# key — never as a standalone signal.
looks_high_entropy() {
  local v="$1"
  (( ${#v} >= 20 )) || return 1
  [[ "$v" =~ [A-Za-z] ]] || return 1
  [[ "$v" =~ [0-9] ]] || return 1
  # Reject pure repetition / obvious low-entropy (e.g. aaaa1111...).
  local uniq
  uniq="$(printf '%s' "$v" | fold -w1 | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  (( uniq >= 8 )) || return 1
  return 0
}

# Key name suggests a secret value.
key_is_secretish() {
  local k="$1"
  k="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
  case "$k" in
    *password*|*passwd*|*secret*|*token*|*api?key*|*apikey*|\
    *access?key*|*accesskey*|*private?key*|*credential*) return 0 ;;
  esac
  return 1
}

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  # (c) per-line suppression markers.
  case "$line" in
    *'# drift-ignore'*|*'#drift-ignore'*|*'<!-- drift-ignore -->'*) continue ;;
  esac

  # --- Known credential shapes (value-shape match, key-agnostic) ----------

  # AWS access key id.
  if [[ "$line" =~ (AKIA|ASIA)[0-9A-Z]{16} ]]; then
    val="${BASH_REMATCH[0]}"
    if ! is_allowlisted "$val"; then
      emit "$lineno" "committed AWS access key id detected" "$(redact "$val")" "$pair_hint"
      continue
    fi
  fi

  # PEM private key header.
  case "$line" in
    *'-----BEGIN '*'PRIVATE KEY-----'*)
      if ! is_allowlisted "$line"; then
        emit "$lineno" "committed PEM private key block detected" "-----BEGIN ***PRIVATE KEY-----" "$pair_hint"
        continue
      fi
      ;;
  esac

  # Slack token.
  if [[ "$line" =~ xox[baprs]-[A-Za-z0-9-]{8,} ]]; then
    val="${BASH_REMATCH[0]}"
    if ! is_allowlisted "$val"; then
      emit "$lineno" "committed Slack token detected" "$(redact "$val")" "$pair_hint"
      continue
    fi
  fi

  # GitHub token — prefixes ghp_/gho_/ghu_/ghs_/ghr_ (personal/oauth/user/
  # server/refresh). Char class is [opsur] to match the documented set; do NOT
  # include 'e' (not a real prefix) and DO include 'r' (refresh tokens).
  if [[ "$line" =~ gh[opsur]_[A-Za-z0-9]{36} ]]; then
    val="${BASH_REMATCH[0]}"
    if ! is_allowlisted "$val"; then
      emit "$lineno" "committed GitHub token detected" "$(redact "$val")" "$pair_hint"
      continue
    fi
  fi

  # --- Keyed high-entropy (key=value where key is secret-named) -----------
  # Match `key = value`, `key: value`, `key="value"` across HCL/YAML/JSON.
  if [[ "$line" =~ ^[[:space:]]*[\"\']?([A-Za-z0-9_.-]+)[\"\']?[[:space:]]*[:=][[:space:]]*(.+)$ ]]; then
    key="${BASH_REMATCH[1]}"
    rawval="${BASH_REMATCH[2]}"
    if key_is_secretish "$key"; then
      val="$(clean_value "$rawval")"
      # Default-to-not-flag: skip empty, placeholders, var-refs, allowlisted,
      # or anything that doesn't clear the conservative entropy bar.
      if [[ -n "$val" ]] && ! is_allowlisted "$val"; then
        skip=0
        # Literal var-ref / interpolation prefixes — these are not secrets.
        # shellcheck disable=SC2016
        case "$val" in
          '${'*|'$'*|'<'*'>'|'{{'*|'%('*|var.*|local.*|data.*|module.*) skip=1 ;;
        esac
        if (( ! skip )); then
          low="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
          case "$low" in
            *changeme*|*change-me*|*placeholder*|*example*|*dummy*|*your_*|*your-*|\
            *xxxx*|*todo*|*redacted*|*sample*|*notreal*|*fake*|\
            password|secret|token|none|null|nil) skip=1 ;;
          esac
        fi
        if (( ! skip )) && looks_high_entropy "$val"; then
          emit "$lineno" \
            "committed high-entropy value assigned to secret-named key '${key}'" \
            "$(redact "$val")" "$pair_hint"
          continue
        fi
      fi
    fi
  fi
done < "$abs"

exit 0
