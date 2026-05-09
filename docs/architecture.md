# Architecture

nyann is a Claude Code plugin. All decisions and mutations live in
shell scripts so the plugin is testable without Claude Code. Scripts
communicate via JSON schemas in `schemas/`.

## At a glance

```
┌──────────────────────────────────────────────────────────┐
│  Skill layer            skills/<name>/SKILL.md           │
│                         UX only — trigger, confirm,      │
│                         report. No business logic.       │
└────────────────────────┬─────────────────────────────────┘
                         │ calls (one direction only)
                         ▼
┌──────────────────────────────────────────────────────────┐
│  Orchestrator layer     bin/{bootstrap,doctor,release,   │
│                         retrofit,pr,ship,commit,…}.sh    │
│                         Top-level coordinators.          │
│                         Own the user-facing JSON.        │
└────────────────────────┬─────────────────────────────────┘
                         │ composes
                         ▼
┌──────────────────────────────────────────────────────────┐
│  Subsystem layer        bin/{detect-stack,compute-drift, │
│                         install-hooks,gen-claudemd,      │
│                         _lib,session-check,…}.sh         │
│                         Focused utilities.               │
│                         Subsystems do NOT call           │
│                         orchestrators.                   │
└────────────────────────┬─────────────────────────────────┘
                         │ reads
                         ▼
┌──────────────────────────────────────────────────────────┐
│  Data + templates       profiles/  schemas/  templates/  │
│                         + ~/.claude/nyann/profiles/      │
└──────────────────────────────────────────────────────────┘
        ▲
        │ JSON contracts (StackDescriptor, Profile,
        │ ActionPlan, DriftReport, DocumentationPlan, …)
        │ flow between every adjacent pair of layers
```

## Layers

Four logical layers. Keep the boundaries clean.

### 1. Skill layer (`skills/*/SKILL.md`)

Claude Code entry points. UX only: trigger, confirm, report.
**No business logic.**

### 2. Orchestrator layer

Every `bin/<name>.sh` that a skill shells into is an orchestrator:
`bootstrap.sh`, `retrofit.sh`, `doctor.sh`, `release.sh`, `pr.sh`,
`commit.sh`, `new-branch.sh`, `sync.sh`, `undo.sh`, `undo-bootstrap.sh`,
`setup.sh`, `switch-profile.sh` (driven by `skills/migrate-profile/`).

Top-level coordinators that compose subsystems and own the
user-facing JSON contract.

**Plan integrity rule:** Orchestrators that hand-build an
`ActionPlan` and feed it to `bootstrap.sh` MUST also pass
`--plan-sha256` (computed via `bin/preview.sh --emit-sha256`) so the
integrity binding stays intact.

**Reversibility rule:** `bootstrap.sh` writes a BootRecord (JSON
manifest + pre-state file copies) under
`<target>/memory/.nyann/bootstraps/<ts>/` before each mutation. The
record is consumed by `undo-bootstrap.sh` to reverse the run. The
`bin/boot-record.sh` helpers (`nyann::br_init`,
`nyann::br_snapshot`, `nyann::br_action_*`, `nyann::br_finalize`)
are the contract; orchestrators source it and call the helpers
inline at every mutation point.

### 3. Subsystem layer

The remaining `bin/*.sh` scripts: `detect-stack.sh`,
`recommend-branch.sh`, `install-hooks.sh`, `compute-drift.sh`,
`gen-claudemd.sh`, `preview.sh`, `_lib.sh`, `session-check.sh`.

Focused utilities that emit/consume JSON schemas.

**Boundary rule:** Subsystems do not call orchestrators. When a
subsystem needs a drift report, it calls `compute-drift.sh`
directly rather than going through `doctor.sh`.

### 4. Data + templates

`profiles/`, `templates/`, `schemas/` plus user profiles at
`~/.claude/nyann/profiles/`.

## Schemas

Every cross-layer contract is locked by a JSON schema in
`schemas/`. Notable ones:

- `StackDescriptor` — output of `detect-stack.sh`
- `BranchingChoice` — output of `recommend-branch.sh`
- `Profile` — `profiles/_schema.json`
- `ActionPlan` — output of bootstrap planning
- `DriftReport` — output of `compute-drift.sh`
- `DocumentationPlan` — output of `route-docs.sh`
- `LinkCheckReport` — output of `check-links.sh`
- `OrphanReport` — output of `find-orphans.sh`

See `schemas/README.md` for the full list.

## MCP boundary

Shell scripts never invoke MCP tools. `bin/detect-mcp-docs.sh` only
reads config; actual MCP calls (Obsidian / Notion page creation,
link verification) are executed by the skill layer, which passes
results back to bash.

## See also

- [Conventions](./principles/conventions.md) — non-negotiables that
  shape every layer
- [Documentation principles](./principles/documentation.md) — the
  Project Memory model nyann's docs system implements
