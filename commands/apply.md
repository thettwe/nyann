---
name: nyann:apply
description: >
  Apply an Infrastructure-as-Code change — the highest-stakes mutator in
  nyann; it can change real cloud infrastructure. Re-runs the plan,
  shows it, confirms, then applies. Unmistakably opt-in: apply is never
  the default and destructive applies require a second explicit confirm.
  For IaC apply intent only (not "apply a patch", "apply formatting", or
  DB migrations).
arguments:
  - name: unit
    description: Repo-relative path of a single module/stack/chart/overlay/playbook to apply. Default applies the whole target root.
    optional: true
  - name: apply
    description: Required to actually mutate. Without it the command previews and exits (preview-by-default).
    optional: true
  - name: confirm-destroy
    description: Required (with an explicit user confirmation) to apply a destructive plan that would destroy/replace resources.
    optional: true
  - name: dry-run
    description: Force preview only — wins over --apply. Nothing is mutated.
    optional: true
  - name: plan
    description: Path to an IacPlan JSON from a prior /nyann:plan run, to apply the exact previewed plan.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:apply

Wraps `bin/iac-apply.sh`. **Highest-stakes mutator — can change real
cloud infrastructure.** Apply is NEVER the default. Flow:

1. Confirm IaC apply intent + an infra signal (not "apply a patch").
2. Preview first: `bin/iac-apply.sh --target <cwd> [--unit <path>]`
   (no `--apply`) → `status:"preview"`, mutates nothing. Show the
   add/change/destroy summary.
3. Confirm with the user. **AskUserQuestion is MANDATORY on a
   destructive plan** (any `destroy > 0`, or any advisory plan).
4. Apply: add `--apply` (and `--confirm-destroy --confirmed` ONLY after
   the user confirms a destroy).

Gate ladder (enforced in the script): plan obtained first → Gate 1
preview-by-default (no `--apply` or any `--dry-run` → preview;
`--dry-run` beats `--apply`) → Gate 2 destructive confirmation
(destructive plan passes only with `--confirm-destroy true` AND
`--confirmed true`, else `refused`) → Gate 3 CLI presence (absent →
`skipped`) → execute (tool output goes to your terminal, never
captured) → write an IacApplyRecord (metadata only — no secrets/state).

| `.status` | Meaning |
|---|---|
| `applied` | Apply ran — read `.exit_code`; see `.record_path`. |
| `preview` | No `--apply` (or `--dry-run`) — nothing applied. |
| `refused` | A gate blocked it (e.g. unconfirmed destroy). Exit 1. |
| `skipped` | CLI/backend/creds absent. Exit 0. Nothing applied. |

See `skills/iac-apply/SKILL.md` for the full gate ladder and the
DISAMBIGUATION that keeps `/nyann:apply` off the generic word "apply".
To only preview → `/nyann:plan`.
