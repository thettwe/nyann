---
name: nyann:gh-protect
description: >
  Audit or apply GitHub branch protection, tag rulesets, signing
  requirements, and repo settings based on the active profile.
arguments:
  - name: profile
    description: Override the active profile name. Defaults to the profile resolved from preferences or CLAUDE.md markers.
    optional: true
  - name: check
    description: Audit-only mode (read-only). Shows drift between profile expectations and GitHub state. This is always run first even when applying.
    optional: true
  - name: owner
    description: GitHub owner. Auto-resolved from `git remote get-url origin` when omitted.
    optional: true
  - name: repo
    description: GitHub repo name. Auto-resolved from `git remote get-url origin` when omitted.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:gh-protect

Wraps `bin/gh-integration.sh`. Two modes:

| Mode | What happens |
|---|---|
| `--check` (default) | Read-only audit. Emits a ProtectionAudit JSON showing drift between profile expectations and GitHub state. |
| apply (on confirmation after audit) | Tightens branch protection, tag rulesets, and repo settings to match the profile. Never downgrades stricter remote rules. |

## When to invoke

- After changing `.github` fields in your profile → audit and apply.
- Periodic check that protection hasn't drifted → audit only.
- After bootstrap if protection wasn't applied (e.g. `gh` was missing
  at bootstrap time) → apply now.

## Output

- **Audit**: ProtectionAudit JSON (`schemas/protection-audit.schema.json`)
  with per-branch, per-rule drift classification (critical / warn / ok).
- **Apply**: GhIntegrationResult JSON
  (`schemas/gh-integration-result.schema.json`) with `applied[]`,
  `noop[]`, `errors[]`.

## Requires

- `gh` CLI installed and authenticated (`gh auth status`).
- Repository must have a GitHub remote.

See also:
- `/nyann:doctor` — includes protection audit as one health signal
- `/nyann:bootstrap` — applies protection during initial setup
- `/nyann:inspect-profile` — view the `.github` block in the active profile
