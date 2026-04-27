---
name: nyann:bootstrap
description: >
  Explicit entry point for nyann's bootstrap flow. Does exactly what the
  natural-language trigger ("set up this project") does, but skips intent
  detection so users who prefer slash commands can opt in directly.
arguments:
  - name: profile
    description: Optional profile name to apply. If provided, skip stack detection's recommendation step and load this profile via bin/load-profile.sh. Fall back to the skill's default matching if omitted.
    optional: true
---
**Plugin root:** This is a Claude Code plugin, NOT a CLI tool. Do NOT
search via `which`, `npm list`, `pip list`, or `brew list`. This file
is at `<plugin_root>/commands/`. All scripts: `<plugin_root>/bin/`.
Read the matching `skills/*/SKILL.md` for the full flow.


# /nyann:bootstrap

Run the same phased flow as the `bootstrap-project` skill (see
`skills/bootstrap-project/SKILL.md`):

1. `bin/detect-stack.sh` to produce a StackDescriptor.
2. Profile resolution:
   - If `--profile <name>` was passed on the command line, call
     `bin/load-profile.sh <name>` and short-circuit detection's
     recommendation.
   - Otherwise, pick a profile per the rules in SKILL.md §2.
3. `bin/recommend-branch.sh` unless the profile pins a strategy.
4. `bin/route-docs.sh` to produce a DocumentationPlan.
5. Assemble an ActionPlan; pipe through `bin/preview.sh`.
6. On confirmation, capture the plan SHA-256 (`bin/preview.sh --emit-sha256`)
   and run `bin/bootstrap.sh --plan <confirmed> --plan-sha256 <hex>` with
   `--profile`, `--doc-plan`, `--stack`, and `--project-name`. The SHA
   binding is required; bootstrap refuses to run without it.
7. Offer the three post-bootstrap nudges (save profile / doctor /
   GitHub branch protection).

**Don't re-invent what the skill already does.** This command is a
deterministic entry point; the logic lives in `skills/bootstrap-project/`.
If the argument parser sees `--profile`, pass it through to the skill's
profile-resolution step (which would otherwise prompt for one).

See also:
- `/nyann:doctor` — audit without changing anything.
- `/nyann:commit` — smart commit message generation.
