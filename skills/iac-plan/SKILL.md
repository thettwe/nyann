---
name: iac-plan
description: >
  Preview an Infrastructure-as-Code change WITHOUT applying it. Runs
  `bin/iac-plan.sh`, which detects the repo's IaC tool (terraform,
  opentofu, aws-cdk, pulumi, helm, kubernetes, kustomize, ansible),
  shells out to the user's already-authenticated CLI, and renders a
  normalized add/change/destroy summary. READ-ONLY — it never mutates
  infrastructure. TRIGGER when the user says "terraform plan",
  "preview my infra change", "what will this deploy", "cdk diff",
  "pulumi preview", "show me the terraform diff", "dry-run the infra
  change", "what would terraform/tofu/cdk/pulumi do", "plan the
  infrastructure", "kubectl diff", "helm diff", "what does this
  deploy change", "/nyann:plan".
  DISAMBIGUATION — fire ONLY for IaC plan intent on a detected infra
  repo. Do NOT trigger on the bare word "plan": this is NOT project
  planning, NOT sprint/roadmap planning, NOT `sc:*` task planning, NOT
  Claude's ExitPlanMode / "make a plan" for code work. "plan a feature",
  "plan my week", "let's plan the refactor" → ignore. Require an
  infra signal (a tool name like terraform/tofu/cdk/pulumi/helm/kubectl,
  OR the word "infra"/"infrastructure"/"deploy", OR a detected
  `iac.tool` in the stack descriptor). With no infra signal, do NOT
  trigger. To apply the change after previewing, that's `/nyann:apply`
  (the iac-apply skill) — iac-plan never applies.
---

# iac-plan

Wraps `bin/iac-plan.sh`. It detects the repo's `iac.tool`, dispatches
to the per-tool adapter (`bin/iac-plan/<tool>.sh`), captures whatever
machine-readable plan the tool offers, and emits a normalized **IacPlan**
JSON on stdout (schema: `schemas/iac-plan.schema.json`). This skill is
READ-ONLY: it previews, it never applies. To apply, hand off to
`/nyann:apply`.

## 1. Confirm this is an IaC repo before running

iac-plan is only meaningful on an infrastructure repo. Before invoking,
satisfy yourself there's an infra signal — a tool name in the request
(terraform / tofu / cdk / pulumi / helm / kubectl / kustomize /
ansible), an explicit "infra"/"deploy" intent, OR a detected `iac.tool`
in the stack descriptor (`bin/detect-stack.sh --path <cwd>` →
`.iac.tool`). If there's no infra signal, this is the wrong skill — see
DISAMBIGUATION in the frontmatter and do not run.

## 2. Scope: whole target or a single unit

By default iac-plan previews the whole target root (`unit:"."`). When
the user names a specific module/stack/chart/overlay/playbook (or the
repo is a monorepo with multiple units), scope it with `--unit`:

```
bin/iac-plan.sh --target <cwd> [--unit <repo-rel-path>]
```

`--unit` is a **repo-relative** path resolved under the target with a
traversal guard — a path that escapes the target is refused (see step
4). Omit it to plan the root.

## 3. Invoke

```
bin/iac-plan.sh --target <cwd> [--unit <repo-rel-path>]
```

The script emits one IacPlan JSON object on stdout. It runs the cloud
CLI only inside the adapter (which the operator invoked by asking for a
plan) — detection itself is pure filesystem work and never auto-runs a
cloud CLI behind the user's back. nyann handles no credentials: the
adapter inherits whatever auth the user's CLI already has.

## 4. Branch on `status` — this drives everything

| `status` | Meaning | What to do |
|---|---|---|
| `planned` | A plan ran and produced a summary. | Render the summary (step 5). Only this status leads to an apply offer. |
| `skipped` | The CLI, backend, or credentials were absent — **no plan ran** (exit 0). | Surface `.message` verbatim (e.g. "terraform CLI not installed", "no backend configured"). Do NOT offer apply — there's nothing to apply. Tell the user what's missing. |
| `refused` | A precondition failed (exit 1) — unknown tool, or `--unit` escaped the target. | Surface `.message`. This is bad input, not a missing tool. Fix the input (correct the unit path, confirm the repo's tool) and retry. |

`skipped` is a *success* outcome of "I couldn't run a plan here", not an
error — never present it as a failure, and never offer apply after it.

## 5. Render the summary (status: planned)

Read these fields off the IacPlan and show them back plainly:

- `.tool` — which tool produced the plan.
- `.unit` — the unit that was planned (`.` = root).
- `.summary.add` / `.summary.change` / `.summary.destroy` — the resource
  action counts. Show them as e.g. **"+3 add, ~1 change, -2 destroy"**.
- `.destructive` — whether this plan would destroy/replace a resource.
- `.destructive_known` — confidence in that verdict (see below).
- `.message` — a one-line summary; relay it.
- `.raw_path` — absolute path to the raw tool output, written **outside
  the repo** (never committed). Offer it if the user wants the full
  diff; do not paste raw plan contents into chat unprompted (it may
  contain resource addresses / config values).

### Structured vs advisory tools — say which you're looking at

- **Structured** (terraform, opentofu, aws-cdk, pulumi):
  `destructive_known:true`. The add/change/destroy counts are real, and
  `destructive` = (`summary.destroy > 0`). Trust the numbers.
- **Advisory** (helm, kubernetes, kustomize, ansible):
  `destructive_known:false`, all summary counts `0`, and `destructive`
  is conservatively **true**. These tools only emit a text diff in
  v1.13.0 — nyann cannot count destruction from it, so it treats the
  change as **potentially destructive** (fail-safe). Tell the user the
  counts are 0 because they're *unknown*, not because the change is
  safe, and point them at `.raw_path` to read the actual diff.

## 6. Destructive plan → ask before offering apply

When `.destructive` is `true` (a structured plan with `destroy > 0`, OR
any advisory plan), do NOT casually suggest applying. **You MUST call
the `AskUserQuestion` tool** (not plain text) to surface the stakes
before any apply path is even offered:

```json
{
  "questions": [
    {
      "question": "This plan is destructive — it would destroy or replace real infrastructure. What next?",
      "header": "Destructive plan",
      "multiSelect": false,
      "options": [
        { "label": "Stop here (Recommended)", "description": "Just show the preview. Nothing is applied. Review the diff and decide later." },
        { "label": "Proceed to apply", "description": "Hand off to /nyann:apply, which will require an explicit destroy confirmation before mutating." }
      ]
    }
  ]
}
```

For an **advisory** destructive plan, add that the destroy count is
unknown (`destructive_known:false`) — the tool gave only a text diff, so
"destructive" here means "could not be proven safe." Recommend reading
`.raw_path` before proceeding.

If the user picks "Proceed to apply", hand off to `/nyann:apply` (step
7) — never apply from this skill.

## 7. Non-destructive plan → offer apply, don't auto-run it

When `.destructive` is `false` (only possible for a structured tool with
`destroy == 0`), it's safe to offer the apply step. State the
add/change counts and ask if they want to apply via `/nyann:apply`.
Still don't run apply from here — iac-plan is preview-only by contract.

## When to hand off

- "Now apply it" / "go ahead and deploy" / "run the apply" →
  `/nyann:apply` (iac-apply skill). It re-runs this plan, requires an
  explicit `--apply`, and gates destructive changes behind an extra
  confirmation. Never apply from iac-plan.
- "plan a feature" / "plan my sprint" / "make a plan for the refactor"
  → NOT this skill. This is code/project planning, not IaC. See
  DISAMBIGUATION.
- "scan for infra drift" / "are my modules pinned" → `/nyann:doctor`
  (it runs `iac-drift-scan.sh`, a filesystem-only IaC audit — no cloud
  CLI, no plan).
