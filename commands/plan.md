---
name: nyann:plan
description: >
  Preview an Infrastructure-as-Code change without applying it. Detects
  the repo's IaC tool (terraform, opentofu, aws-cdk, pulumi, helm,
  kubernetes, kustomize, ansible), shells out to your already-authed
  CLI, and renders an add/change/destroy summary. Read-only — never
  mutates infra. For IaC plan intent only (not project/sprint planning).
arguments:
  - name: unit
    description: Repo-relative path of a single module/stack/chart/overlay/playbook to plan. Default plans the whole target root.
    optional: true
  - name: target
    description: Repo root to plan. Defaults to the current directory.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:plan

Wraps `bin/iac-plan.sh`. READ-ONLY IaC preview — it never applies. Flow:

1. Confirm there's an infra signal (a tool name, "infra"/"deploy"
   intent, or a detected `.iac.tool`). If not, this is the wrong skill.
2. Run `bin/iac-plan.sh --target <cwd> [--unit <path>]` → IacPlan JSON.
3. Branch on `.status`: `planned` → render add/change/destroy summary;
   `skipped` → surface the missing CLI/backend/creds, do NOT offer
   apply; `refused` → fix the bad input (unknown tool / unit traversal).
4. For a destructive plan, AskUserQuestion before offering apply.

| `.status` | Meaning |
|---|---|
| `planned` | A plan ran — render the summary. |
| `skipped` | CLI/backend/creds absent (exit 0) — nothing to apply. |
| `refused` | Bad input (exit 1) — unknown tool or `--unit` traversal. |

Structured tools (terraform/opentofu/aws-cdk/pulumi) report real
counts; advisory tools (helm/kubernetes/kustomize/ansible) emit a text
diff only, counts are 0, and the change is treated as potentially
destructive.

See `skills/iac-plan/SKILL.md` for the full flow and the DISAMBIGUATION
that keeps `/nyann:plan` off the bare word "plan" (project/sprint
planning, ExitPlanMode). To apply after previewing → `/nyann:apply`.
