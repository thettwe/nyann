#!/usr/bin/env bash
# setup-signing.sh — configure LOCAL commit + tag signing for a repo.
#
# Usage:
#   setup-signing.sh --target <repo> --mode ssh|gitsign|gpg [--key <path-or-id>]
#   setup-signing.sh --target <repo> --mode <m> [--key <k>] --apply
#   setup-signing.sh --target <repo> --undo
#
# The LOCAL half of nyann's signing posture: gh-protect audits (and can
# require) signing on the remote; this script makes the repo actually
# produce signed commits/tags. REPO-LOCAL git config only — never
# --global — so one repo's signing choice can't leak into another's.
#
# Modes:
#   ssh      gpg.format=ssh + user.signingkey=<pubkey path> +
#            commit.gpgsign=true + tag.gpgsign=true. Default key: the
#            first of ~/.ssh/id_ed25519.pub / id_ecdsa.pub / id_rsa.pub;
#            override with --key. git-native (>= 2.34), zero extra tools.
#   gitsign  gpg.format=x509 + gpg.x509.program=gitsign +
#            commit.gpgsign=true + tag.gpgsign=true. Keyless sigstore
#            signing (Fulcio cert + Rekor transparency log; expect an
#            OIDC browser step per signature). Refuses (no writes) when
#            the gitsign binary is absent.
#   gpg      gpg.format=openpgp + commit.gpgsign=true + tag.gpgsign=true
#            (+ user.signingkey=<key id> when --key is given).
#
# Preview-before-mutate: the default invocation renders the exact
# `git config` delta (current → new) to stderr, emits the would-be
# SigningSetupRecord to stdout, writes NOTHING, and exits 2 — the same
# confirm contract release.sh uses. `--apply` executes the delta and
# writes the record to <target>/memory/.nyann/signing-setup.json; the
# PRIOR values in an existing record are preserved across re-applies so
# `--undo` always restores the ORIGINAL pre-nyann configuration
# (unsetting keys that were unset) and removes the record.
#
# Exit codes:
#   0 — applied / undone
#   2 — preview rendered; re-run with --apply to execute
#   1 — hard error (bad mode, gitsign missing, no ssh key resolvable,
#       nothing to undo)
#
# Requires jq. git required (obviously).

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "${_script_dir}/_lib.sh"

nyann::require_cmd jq

target=""
mode=""
key=""
apply=false
undo=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   target="${2-}"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --mode)     mode="${2-}"; shift 2 ;;
    --mode=*)   mode="${1#--mode=}"; shift ;;
    --key)      key="${2-}"; shift 2 ;;
    --key=*)    key="${1#--key=}"; shift ;;
    --apply)    apply=true; shift ;;
    --undo)     undo=true; shift ;;
    -h|--help)  sed -n '3,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) nyann::die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" && -d "$target" ]] || nyann::die "--target <repo> is required and must be a directory"
git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || nyann::die "--target is not a git repo: $target"
$apply && $undo && nyann::die "--apply and --undo are mutually exclusive"

record_dir="$target/memory/.nyann"
record_file="$record_dir/signing-setup.json"

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# current_value <key> — the repo-LOCAL value, or empty when unset.
current_value() {
  git -C "$target" config --local --get "$1" 2>/dev/null || true
}

# --- undo --------------------------------------------------------------------

if $undo; then
  [[ -f "$record_file" ]] || nyann::die "nothing to undo — no signing-setup record at $record_file"
  jq -e 'type == "object" and has("entries")' >/dev/null 2>&1 "$record_file" \
    || nyann::die "signing-setup record is malformed: $record_file"
  while IFS=$'\t' read -r k prior; do
    [[ -z "$k" ]] && continue
    if [[ "$prior" == $'\x01null' ]]; then
      git -C "$target" config --local --unset "$k" 2>/dev/null || true
      nyann::log "setup-signing: unset $k (was unset before)"
    else
      git -C "$target" config --local "$k" "$prior"
      nyann::log "setup-signing: restored $k = $prior"
    fi
  done < <(jq -r '.entries[] | [.key, (.prior // "\u0001null")] | @tsv' "$record_file")
  rm -f "$record_file"
  nyann::log "setup-signing: undone — original signing configuration restored"
  exit 0
fi

# --- resolve the mode's config set -------------------------------------------

case "$mode" in
  ssh)
    resolved_key="$key"
    if [[ -z "$resolved_key" ]]; then
      for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
        [[ -f "$cand" ]] && { resolved_key="$cand"; break; }
      done
    fi
    [[ -n "$resolved_key" ]] \
      || nyann::die "no SSH public key found under ~/.ssh — pass --key <path-to-.pub> (or generate one: ssh-keygen -t ed25519)"
    [[ -f "$resolved_key" ]] \
      || nyann::die "--key does not exist: $resolved_key (want a .pub file for ssh mode)"
    keys=(gpg.format user.signingkey commit.gpgsign tag.gpgsign)
    vals=(ssh "$resolved_key" true true)
    ;;
  gitsign)
    if ! nyann::has_cmd gitsign; then
      nyann::die "gitsign is not installed — install it first (brew install gitsign / go install github.com/sigstore/gitsign@latest), or use --mode ssh for git-native signing"
    fi
    keys=(gpg.format gpg.x509.program commit.gpgsign tag.gpgsign)
    vals=(x509 gitsign true true)
    ;;
  gpg)
    keys=(gpg.format commit.gpgsign tag.gpgsign)
    vals=(openpgp true true)
    if [[ -n "$key" ]]; then
      keys+=(user.signingkey)
      vals+=("$key")
    fi
    ;;
  "") nyann::die "--mode ssh|gitsign|gpg is required (or --undo)" ;;
  *)  nyann::die "unknown mode: $mode (want ssh|gitsign|gpg)" ;;
esac

# --- build the record (preserving ORIGINAL priors across re-applies) ---------

prior_of() { # <key> → prior value from an existing record, sentinel-null aware
  # NB: array-wrap + length check, not first(): an empty stream from
  # first() emits NOTHING (not null), which would read as an empty prior.
  jq -r --arg k "$1" \
    '[.entries[] | select(.key == $k)]
     | if length == 0 then "\u0002absent"
       elif .[0].prior == null then "\u0001null"
       else .[0].prior end' \
    "$record_file" 2>/dev/null || printf '\x02absent'
}

entries='[]'
i=0
for k in "${keys[@]}"; do
  v="${vals[$i]}"
  cur=$(current_value "$k")
  prior_json="null"
  if [[ -f "$record_file" ]]; then
    p=$(prior_of "$k")
    if [[ "$p" == $'\x02absent' ]]; then
      [[ -n "$cur" ]] && prior_json=$(jq -n --arg v "$cur" '$v')
    elif [[ "$p" == $'\x01null' ]]; then
      prior_json="null"
    else
      prior_json=$(jq -n --arg v "$p" '$v')
    fi
  else
    [[ -n "$cur" ]] && prior_json=$(jq -n --arg v "$cur" '$v')
  fi
  entries=$(jq --arg k "$k" --argjson prior "$prior_json" --arg new "$v" --arg cur "$cur" \
    '. + [{key: $k, prior: $prior, new: $new, current: (if $cur == "" then null else $cur end)}]' <<<"$entries")
  i=$((i + 1))
done

record=$(jq -n --arg mode "$mode" --arg ts "$(now)" --argjson entries "$entries" \
  '{mode: $mode, applied_at: $ts, entries: ($entries | map({key, prior, new}))}')

# --- preview -----------------------------------------------------------------

{
  printf '\nsetup-signing (%s) — repo-local git config delta for %s:\n\n' "$mode" "$target"
  jq -r '.[] | "  \(.key): \(.current // "(unset)") → \(.new)"' <<<"$entries"
  printf '\n'
} >&2

if ! $apply; then
  printf '%s\n' "$record"
  nyann::warn "preview only — re-run with --apply to write the config (undo later with --undo)"
  exit 2
fi

# --- apply -------------------------------------------------------------------

i=0
for k in "${keys[@]}"; do
  git -C "$target" config --local "$k" "${vals[$i]}"
  i=$((i + 1))
done

mkdir -p "$record_dir"
printf '%s\n' "$record" > "$record_file"
printf '%s\n' "$record"
nyann::log "setup-signing: applied $mode signing (record: memory/.nyann/signing-setup.json; reverse with --undo)"
nyann::log "setup-signing: verify with: git -C $target commit --allow-empty -S -m 'chore: signing smoke test' (then reset)"
exit 0
