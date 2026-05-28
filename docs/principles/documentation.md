# Documentation principles

**Status:** Active (informs all v1.6.0+ documentation decisions)
**Introduced:** v1.6.0
**Last updated:** 2026-05-06

## Mission

nyann's documentation system has one job: give AI agents the right context
to work on your codebase, without overload.

Most existing doc systems target human readers — that fits the era they
were built in. AI agents now read, write, and act on the same docs, with
finite context windows, retrieval-driven access, and no tolerance for
prose padding. nyann's documentation, called **Project Memory**, is
designed for those constraints first. Humans still benefit, because
high-signal structured prose serves both audiences.

## What is Project Memory?

Project Memory is the durable, structured knowledge layer of your
codebase. It lives in `docs/` (or an MCP-routed equivalent) and answers
one question:

> "What does an AI agent need to know to be effective on this code?"

Not "what should a new hire read?" Not "what's nice to write down?"
Project Memory is narrower: only the context that helps an AI agent
(or a future-you who has mostly forgotten) make correct decisions.

Five properties define it. Every template, drift check, and feature
must serve at least one. Features that serve none are out of scope.

### 1. AI-retrieval-first

Designed for agents to retrieve on demand, not for humans to read
end-to-end.

- **Bounded scope per doc.** One doc = one topic. Agents pull individual
  docs, not whole wikis.
- **Predictable structure.** Consistent headings (`## Constraints`,
  `## Interfaces`, `## Invariants`) so agents navigate without
  re-learning every file.
- **Decision rationale.** Why X over Y, what depends on what, what
  we'd revisit.
- **Anti-patterns called out.** "DO NOT add an endpoint without
  going through the gateway" beats narrative.

Humans still read these. They read them like reference manuals, not
novels.

### 2. Size-budgeted

Sized to fit AI context windows, not unlimited like a wiki.

- **CLAUDE.md is router-mode.** ≤ 3 KB soft, ≤ 8 KB hard. It is a
  manifest into Project Memory, not content.
- **Each doc earns its tokens.** Padding costs retrieval budget for
  everyone reading next.
- **Cross-links expand context just-in-time.** An agent follows links
  to specific component docs only when relevant, instead of being
  handed everything upfront.

This is the inverse of "capture everything" systems. Project Memory
is curated, not captured.

### 3. Drift-aware

Stale or orphaned docs mislead AI. Drift detection is hygiene, not
nice-to-have.

- **Broken internal links** — surfaced by `doctor`, gated in CI by
  `governance-check`.
- **MCP-backed link verification** — runs via the MCP client when
  Obsidian/Notion are wired.
- **Orphans** (docs nothing else references) — flagged.
- **Staleness** (docs untouched past the profile's threshold) — flagged.
- **Health trending** — Project Memory hygiene tracked over time.

A misleading doc is worse than a missing one.

### 4. Storage-agnostic

The user picks where Project Memory lives. nyann is plumbing, not a
silo.

| Backend | When to pick |
|---|---|
| **Local** | You want docs alongside the code in the repo |
| **Obsidian** (MCP) | You already use a personal or team knowledge graph |
| **Notion** (MCP) | Your team is already there |

Same principles, same templates, same drift detection across all
three. Equal citizens — no preferred backend.

The `memory/` folder is always local, regardless of backend choice.
It is the ephemeral scratch layer, not part of Project Memory.

### 5. Dual-audience without compromise

Every Project Memory doc reads well to humans. AI-first ≠
human-hostile.

The principles that serve AI (high signal density, predictable
structure, decision rationale, bounded scope) are the same that
serve experienced humans reading reference docs. The audience this
design *doesn't* serve is the casual-narrative reader — that
audience lives in `README.md` and external docs sites, not Project
Memory.

## The layered model

A nyann-bootstrapped repo has three knowledge layers, plus a
fourth layer Claude Code manages on its own.

```
                    ┌──────────────────────────────┐
                    │  CLAUDE.md (router)          │
                    │  ≤ 3 KB soft / 8 KB hard     │
                    │  Loaded every conversation   │
                    └──────────────┬───────────────┘
                                   │ links to
              ┌────────────────────┼────────────────────┐
              ▼                                         ▼
   ┌──────────────────────┐            ┌─────────────────────────────┐
   │  docs/               │            │  memory/                    │
   │  Project Memory      │            │  Ephemeral team scratch     │
   │  Durable knowledge   │            │  Mid-session decisions,     │
   │  Loaded on demand    │            │  TODOs, open questions      │
   │  via CLAUDE.md links │            │  Loaded when read           │
   └──────────────────────┘            └─────────────────────────────┘

   Out of nyann's scope but worth knowing:
   ┌───────────────────────────────────────────────────────────────┐
   │  ~/.claude/projects/<encoded>/memory/  (per-user, hidden)     │
   │  Claude Code curates this across conversations automatically. │
   │  Distinct from nyann's memory/, which is team-shared in git.  │
   └───────────────────────────────────────────────────────────────┘
```

CLAUDE.md is the router. Project Memory is the durable brain.
`memory/` is the ephemeral scratch where mid-session decisions live
until they're promoted to Project Memory or forgotten. Claude
Code's per-user auto-memory is its own private working memory —
nyann does not manage it.

| Layer | Location | Curated by |
|---|---|---|
| **CLAUDE.md** | repo root | nyann + maintainer |
| **Project Memory** | `docs/` (or MCP) | team |
| **`memory/`** | repo (always local) | Claude + team |
| **Claude auto-memory** | `~/.claude/projects/<encoded>/memory/` | Claude Code (private) |

## What Project Memory is not

- **Not a personal knowledge management system.** "Second Brain"
  tools (Mem, Logseq, Tana) target individual humans organizing
  personal notes across projects. Project Memory is codebase-scoped,
  team-shared, AI-readable.
- **Not a consumer docs site.** External docs (api.example.com,
  developer portals) target end users with tutorials and polished
  reference. nyann does not compete there.
- **Not a wiki.** Wikis are unbounded, narrative-friendly. Project
  Memory is bounded, archetype-driven, retrieval-friendly.
- **Not self-editing.** Drift detection surfaces problems; humans and
  AI fix them. Project Memory never auto-edits itself.

## Implications for nyann

Existing features that already align:

- Router-mode CLAUDE.md generation (property 2)
- Drift detection — broken links, orphans, staleness (property 3)
- MCP routing for Obsidian/Notion (property 4)
- ADR scaffolding — structured, decision-rationale-rich (property 1)
- Health trending (property 3)

Gaps closed in v1.6.0:

- **Codebase-aware categorization** — scaffolds depend on the
  system's archetype (api-service, cli-tool, library, …), not its
  language.
- **New templates aligned to AI retrieval** — `api-reference`,
  `runbook`, `deployment`, `glossary` primarily serve AI-agent
  context.
- **`memory/` framing** — repositioned as the ephemeral scratch
  layer, distinct from Project Memory.
- **Self-compliance** — nyann's own `CLAUDE.md` brought under the
  3 KB router-mode budget.

Gaps closed in v1.7.0:

- **Glossary auto-population** — `bin/scaffold-glossary.sh` seeds
  `docs/glossary.md` from detected exported types per language
  (Go, TS, JS, Python, Rust, Java, Kotlin, Swift). Marker-bracketed
  auto block; user content outside the markers is preserved.
  Profile-gated via `documentation.glossary.auto_populate`.
  Serves property 1 (AI-retrieval-first) — finally puts content in
  the file we already shipped a template for.

Gaps closed in v1.9.0:

- **Archetype-specific drift checks** — `bin/compute-drift.sh` now
  emits `misplaced[]` for files that live outside their archetype's
  expected location, and `doctor` surfaces "missing for archetype"
  warnings. The CLI-variant `--help` matching and API-reference
  endpoint validation are still future work but the framework is
  in place.

Gaps closed in v1.11.0:

- **Documentation correlations via profile composition** —
  `extends` lets profiles inherit a shared documentation policy
  (correlations, staleness thresholds) without duplicating it in
  every child profile. Serves property 3 (drift-aware).

## Adding a new doc template

Before any new template ships, answer:

1. **Which Project Memory property does it serve?** If none, it
   doesn't belong.
2. **Which archetype(s)?** Generic templates are a smell —
   `architecture.tmpl` is an exception, not the pattern to copy.
3. **Is it AI-retrievable on its own?** Bounded scope per doc is
   non-negotiable.
4. **Same content for AI and humans, or different?** If different,
   the AI-first version wins; narrative belongs in README or external
   docs.

Better to ship four well-fitting templates than ten generic ones.

Existing templates (`architecture`, `prd`, `adrs`, `research`,
`memory`) predate this principles doc and are grandfathered in. They
will be refined toward these principles over time but are not
required to pass the four-question test retroactively.

## Open questions

- **Deeper archetype-specific validation.** v1.9.0 added structural
  drift checks (misplaced files, missing files for archetype), but
  the content-level checks remain open: API services should validate
  "every endpoint appears in `api-reference.md`"; CLIs should match
  documented commands against `--help`. Targeting v1.12+ as part of
  P4 (documentation staleness detector).
- **MCP-side templates.** Obsidian and Notion users get the same
  Markdown today. Notion-block-formatted variants remain open.
- **Glossary depth — comments + private types.** v1.7.0 only seeds
  exported / public types. A future iteration could surface JSDoc /
  docstring comments next to each entry, and optionally include
  internal types behind a profile flag for repos that document
  internals as part of their AI retrieval surface.
- **Public-doc drift detection.** Counts and feature claims in
  README/CONTRIBUTING/architecture docs are tracked manually today.
  Targeting v1.12+ as P7 — a docs-drift scanner that catches stale
  numbers and missing v1.X feature mentions before they ship.

## Versioning these principles

Versioned with nyann itself. Material changes (adding a property,
redefining the layered model, changing the storage equal-citizen
rule) are major-version events. Refinements (wording, examples,
deferred-to-shipped status) are minor-version events.
