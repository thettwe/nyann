---
name: nyann:setup-signing
description: >
  Configure local commit + tag signing for this repo — SSH signing
  (git-native, recommended), sigstore/gitsign (keyless), or classic GPG.
  Previews the exact repo-local git-config delta before writing, records
  what changed, and is fully reversible with --undo. The remote
  enforcement half (require signed commits on GitHub) lives in
  /nyann:gh-protect.
arguments:
  - name: mode
    description: ssh | gitsign | gpg. Recommended default is ssh (no new tooling; uses an existing SSH key).
    optional: true
  - name: key
    description: SSH public-key path (ssh mode) or GPG key id (gpg mode). ssh mode auto-resolves ~/.ssh/id_*.pub when omitted.
    optional: true
  - name: undo
    description: Restore the original pre-nyann signing configuration from the recorded setup and remove the record.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read `skills/setup-signing/SKILL.md` for the full flow.


# /nyann:setup-signing

Wraps `bin/setup-signing.sh` — preview-before-mutate (bare call renders
the config delta and exits 2; `--apply` executes), repo-local git config
only (never --global), and a SigningSetupRecord under
`memory/.nyann/signing-setup.json` whose original prior values survive
re-applies so `--undo` always returns to the pre-nyann state.

After applying, the skill smoke-tests with an empty signed commit and
points at the remote half: `/nyann:gh-protect` for
`require_signed_commits` enforcement, and (ssh mode) adding the public
key to GitHub as a Signing Key so signatures show "Verified".

See also:
- `/nyann:gh-protect` — remote signing enforcement + the signing audit.
- `/nyann:doctor` — surfaces signing drift (declared mode vs. actual config).
