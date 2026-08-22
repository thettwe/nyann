---
name: setup-signing
description: >
  Configure LOCAL commit + tag signing for the current repo — SSH signing
  (git-native, recommended), sigstore/gitsign (keyless x509), or classic
  GPG — previewed before any config write, recorded, and undoable.
  TRIGGER when the user says "sign my commits", "set up commit signing",
  "enable commit signing", "make my commits verified", "configure git
  signing", "enable gitsign", "keyless signing", "sigstore signing",
  "ssh signing", "sign my tags", "undo the signing setup",
  "/nyann:setup-signing".
  Do NOT trigger on "require signed commits on GitHub" / "enforce signing
  on the repo" — that's `gh-protect` (remote branch-protection
  enforcement); this skill is the LOCAL half that makes the repo actually
  produce signatures. Do NOT trigger on "sign the release" alone — tag
  signing rides on the same config this skill writes.
---

# setup-signing

> **Plugin root:** `<plugin_root>/skills/setup-signing/SKILL.md` — the
> script is `<plugin_root>/bin/setup-signing.sh`.

The LOCAL half of nyann's signing posture. `gh-protect` audits (and can
require) signatures on the remote; this skill configures the repo to
produce them. Repo-local `git config` only — never `--global` — recorded
to `memory/.nyann/signing-setup.json` and reversible with `--undo`.

## 1. Pick the mode

Recommend **ssh** unless the user asked for something else — it is
git-native (≥ 2.34), uses the SSH key they already have, and adds zero
tooling. Offer the alternatives honestly:

```json
{
  "questions": [{
    "question": "Which signing mechanism?",
    "header": "Signing",
    "multiSelect": false,
    "options": [
      { "label": "SSH (Recommended)", "description": "git-native, uses your existing SSH key, no new tools. GitHub verifies when the key is added as a Signing Key in your profile." },
      { "label": "gitsign (sigstore)", "description": "Keyless x509 — Fulcio certificate + Rekor transparency log. Requires the gitsign binary and an OIDC browser step per signature." },
      { "label": "GPG", "description": "Classic OpenPGP. Requires a configured GPG key (pass its id via --key)." }
    ]
  }]
}
```

If the user names a mode in their message, skip the question. When the
profile declares `security.commit_signing.mode`, default to that (the
audit flags a mismatch otherwise).

## 2. Preview, confirm, apply

```
bin/setup-signing.sh --target <cwd> --mode ssh|gitsign|gpg [--key <path-or-id>]
```

The bare call renders the exact repo-local `git config` delta
(current → new), writes NOTHING, and exits 2. Show the delta, confirm
with AskUserQuestion, then re-run with `--apply`.

Mode notes:
- **ssh** auto-resolves `~/.ssh/id_ed25519.pub` → `id_ecdsa.pub` →
  `id_rsa.pub`; confirm the resolved key with the user (it's in the
  preview) or pass `--key`. No key at all → the script dies with an
  `ssh-keygen` hint; relay it.
- **gitsign** refuses (no writes) when the binary is absent — relay the
  install hint. Warn BEFORE the user picks it about the per-signature
  OIDC browser flow.
- **gpg** accepts `--key <keyid>`; without it, git falls back to
  gpg-agent's default key.

`--apply` writes the config and a SigningSetupRecord whose PRIOR values
survive re-applies — undo always restores the original pre-nyann state.

## 3. Verify immediately

A wrong signing config makes EVERY commit fail, so smoke-test right
after apply:

```
git -C <cwd> commit --allow-empty -S -m "chore: signing smoke test"
git -C <cwd> log --show-signature -1
git -C <cwd> reset --hard HEAD~1
```

If the smoke test fails, offer `--undo` immediately (the escape hatch)
and surface the underlying error (missing agent, wrong key path, gitsign
OIDC failure) rather than leaving the repo unable to commit.

## 4. Close the loop

- **Remote half:** for signatures to show "Verified" and be enforced,
  point at `gh-protect` (`github.require_signed_commits`) and — for ssh
  mode — remind the user to add the public key to GitHub as a
  **Signing Key** (not just an auth key).
- **Profile:** offer to pin the choice in the profile
  (`security.commit_signing.mode`) so doctor/gh-protect flag drift when
  a clone loses the config.
- **Undo:** `bin/setup-signing.sh --target <cwd> --undo` restores the
  original configuration byte-for-byte and removes the record.
