---
name: iac-apply
description: >
  Actually APPLY an Infrastructure-as-Code change — the highest-stakes
  mutator in nyann; it can mutate real cloud infrastructure. Re-runs the
  plan, shows it, confirms with the user, then invokes `bin/iac-apply.sh
  --apply` (adding `--confirm-destroy` only when the user explicitly
  confirms a destructive change). UNMISTAKABLY opt-in: apply is never the
  default, destructive applies need a second explicit confirmation.
  TRIGGER when the user says "terraform apply", "apply the infra change",
  "deploy this infrastructure", "tofu apply", "cdk deploy", "pulumi up",
  "helm upgrade", "kubectl apply", "apply the plan", "run the apply now",
  "yes apply it" (in an IaC context), "ship the infra change",
  "provision this", "/nyann:apply".
  DISAMBIGUATION — fire ONLY for IaC apply intent on a detected infra
  repo. Do NOT trigger on the generic word "apply": NOT "apply this code
  patch", NOT "apply the suggestion", NOT "apply formatting", NOT "apply
  a migration" (DB migrations are out of scope), NOT "apply for X". An
  infra signal is REQUIRED — a tool name (terraform/tofu/cdk/pulumi/
  helm/kubectl/kustomize/ansible), OR the word "infra"/"infrastructure"/
  "deploy"/"provision", OR a detected `iac.tool` in the stack descriptor.
  With no infra signal, do NOT trigger. To only PREVIEW (no apply),
  that's `/nyann:plan` (the iac-plan skill) — iac-apply always previews
  first internally, but its purpose is the mutation.
---

# iac-apply

Wraps `bin/iac-apply.sh`. **This is the highest-stakes mutator in
nyann** — it can change real cloud infrastructure. Read this end to end
before invoking. The gate ladder below is enforced in the script, not
just prose; your job is to drive the flags in the right order and never
shortcut a confirmation.

The script mirrors `bin/undo.sh`'s preview-before-mutate contract:
**apply is never the default.** Without `--apply` it previews and exits
0. `--dry-run` always wins over `--apply`. A destructive plan needs a
second explicit confirmation on top of `--apply`. The output is a JSON
object on stdout (`status: preview|applied|skipped|refused`, plus
`tool`, `unit`, `summary`, `destructive`, optional `record_path`,
`exit_code`, `message`).

## 0. This skill is opt-in — confirm intent first

Never invoke an apply because a plan looked ready. Only proceed when the
user has clearly asked to apply/deploy/provision on an infra repo (see
DISAMBIGUATION). If they only wanted to see the diff, route to
`/nyann:plan`. Confirm there's an infra signal (a tool name, an
"infra"/"deploy" intent, or a detected `.iac.tool`) before doing
anything.

## 1. Always preview the plan first — show it back

Always obtain an **IacPlan** before applying — `iac-apply.sh` computes
one internally (or reads `--plan <iacplan.json>` if you already ran
`/nyann:plan` and saved it). Either way, run a preview pass first and
**show the add/change/destroy summary to the user**:

```
bin/iac-apply.sh --target <cwd> [--unit <repo-rel-path>]   # no --apply → preview
```

This emits `status:"preview"`, exits 0, and mutates nothing. Render
`.summary` (e.g. **"+3 add, ~1 change, -2 destroy"**), `.destructive`,
and `.destructive_known` exactly as the iac-plan skill does. If the
preview's plan came back `status:"skipped"` (CLI/backend/creds absent),
the apply emits `status:"skipped"` exit 0 — surface `.message`, and
stop: there is nothing to apply. If the plan was `status:"refused"`
(unknown tool / `--unit` traversal), apply emits `status:"refused"`
exit 1 — relay `.message` and fix the input.

## 2. Confirm before applying (MANDATORY on destroy)

This is the human gate. How you confirm depends on whether the plan is
destructive:

### Non-destructive plan (`destructive:false`)

Only possible for a structured tool with `destroy == 0`. Show the
add/change counts and ask a plain yes/no: *"Apply this change?
(+N add, ~M change, no destroys)"*. Proceed only on an explicit yes.
Skip this only if the user already said "just apply it, don't ask".

### Destructive plan (`destructive:true`) — AskUserQuestion is REQUIRED

This covers any structured plan with `destroy > 0` **and every advisory
plan** (helm/kubernetes/kustomize/ansible — `destructive_known:false`,
where destruction can't be ruled out from a text diff). **You MUST call
the `AskUserQuestion` tool** (not plain text) and get an explicit
go-ahead before adding `--confirm-destroy`:

```json
{
  "questions": [
    {
      "question": "This apply is DESTRUCTIVE — it will destroy or replace real infrastructure. Confirm?",
      "header": "Confirm destroy",
      "multiSelect": false,
      "options": [
        { "label": "No, stop (Recommended)", "description": "Do not apply. Nothing is mutated. Re-review the plan first." },
        { "label": "Yes, apply the destroy", "description": "Proceed. Resources WILL be destroyed/replaced — this is not reversible by nyann." }
      ]
    }
  ]
}
```

For an **advisory** destructive plan, add that the destroy count is
unknown (`destructive_known:false`): the tool gave only a text diff, so
nyann treats it as potentially destructive. Strongly recommend reading
the raw diff (the plan's `raw_path`) before confirming.

Pass `--confirm-destroy` **only** after the user picks "Yes". Pass
`--confirmed true` explicitly to record that a human confirmed (the CLI
defaults `--confirmed` to the `--confirm-destroy` value for headless
parity, but this skill should always pass it explicitly after the
AskUserQuestion).

## 3. Invoke the real apply

```
bin/iac-apply.sh \
  --target <cwd> \
  [--unit <repo-rel-path>] \
  [--plan <iacplan.json>] \
  --apply \
  [--confirm-destroy --confirmed]      # ONLY after the user confirms a destroy
```

The script walks this exact gate ladder — drive the flags to match it:

1. **Plan obtained first.** `skipped` plan → `status:"skipped"` exit 0
   (no apply). `refused` plan → `status:"refused"` exit 1.
2. **Gate 1 — preview by default.** No `--apply` (or any `--dry-run`)
   → `status:"preview"`, exit 0, nothing applied. `--dry-run` beats
   `--apply`.
3. **Gate 2 — destructive confirmation.** Reached only with `--apply`
   and no `--dry-run`. Calls `bin/guards/iac-apply-confirmation.sh`.
   Non-destructive plan → guard returns pass + skipped ("not-required")
   and the apply proceeds. Destructive plan → guard passes **only** when
   `--confirm-destroy true` AND `--confirmed true`; otherwise apply
   emits `status:"refused"` exit 1 and nothing is applied. The guard
   fails CLOSED on a missing/unparseable plan.
4. **Gate 3 — CLI presence.** If the apply CLI is absent →
   `status:"skipped"` exit 0, no apply, no record.
5. **Execute.** Runs `(cd <unit_dir> && <tool apply cmd>) >&2` — the
   tool's output goes straight to the operator's terminal and is never
   captured by nyann (it can echo state).
6. **Record.** On a real apply it writes an **IacApplyRecord**
   (`schemas/iac-apply-record.schema.json`) under
   `<target>/memory/.nyann/iac-applies/<ISO-ts>/manifest.json` — metadata
   only (tool, unit, summary, the satisfied gate flags,
   `plan_sha256`, and the apply's honest `exit_code`). NO credentials,
   NO secrets, NO state, NO raw plan bytes.

Per-tool apply command (the script picks it from `tool`):
terraform/opentofu → `terraform|tofu apply -input=false <plan.tfplan>`
(reuses the plan binary iac-plan saved; falls back to `-auto-approve`);
aws-cdk → `cdk deploy --require-approval never`; pulumi →
`pulumi up --yes --non-interactive`; helm →
`helm upgrade --install <unit-basename> .`; kubernetes →
`kubectl apply -f .`; kustomize → `kubectl apply -k .`; ansible →
`ansible-playbook <site.yml|playbook.yml>`.

## 4. Interpret the outcome

Branch on `.status`:

| `status` | What happened | What to tell the user |
|---|---|---|
| `applied` | The apply ran. Read `.exit_code`: 0 = the tool succeeded; non-zero = the tool reported failure (recorded honestly). | Report success/failure with the counts. Point to `.record_path` for the audit record. On non-zero exit, the tool's own output (in their terminal) has the error — relay that they should read it. |
| `preview` | No `--apply` (or `--dry-run` overrode it). Nothing was applied. | Show the summary; if they meant to apply, re-run with `--apply` (and confirm). |
| `refused` | A gate blocked the apply — most often the destructive-confirmation gate without `--confirm-destroy`/`--confirmed`, or a refused plan. Exit 1. Nothing applied. | Relay `.message`. For the destroy case: re-run only after an explicit AskUserQuestion confirm, then pass `--confirm-destroy --confirmed`. |
| `skipped` | CLI/backend/creds absent, or the plan was skipped. Exit 0. Nothing applied, no record. | Surface `.message` (what's missing). Can't proceed until the CLI/creds are present. |

## 5. After a real apply

- Point the user at `.record_path` (the IacApplyRecord) so they — and
  teammates — can audit the change. It's metadata only; it contains no
  secrets or state, so it's safe to commit.
- The tool's actual output (resource diffs, errors) went to their
  terminal, not into nyann's JSON. If they ask "what exactly changed",
  direct them to that output and to the plan's `raw_path`.
- nyann does NOT roll back infrastructure. If the apply was wrong, the
  remedy is a new corrective plan/apply (or the tool's own state
  recovery), not a nyann undo.

## When to hand off

- "Just show me the diff" / "preview only" / "don't apply" →
  `/nyann:plan` (iac-apply previews internally but its purpose is the
  mutation; for preview-only use plan).
- "apply this code patch" / "apply the review suggestion" / "apply
  formatting" / "apply the DB migration" → NOT this skill. See
  DISAMBIGUATION — those are not IaC applies.
- "undo the infra change" → there is no nyann undo for infrastructure.
  Explain that the fix is a corrective apply or the tool's own state
  recovery, never a nyann rollback.
