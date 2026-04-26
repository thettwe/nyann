---
status: accepted
date: 2026-04-23
decision-makers:
---

# ADR-000 — Record architecture decisions

## Context and problem statement

We need a lightweight record of the technical choices we make, so that future contributors (and future us) can tell intentional decisions apart from incidental drift.

## Decision drivers

* Low friction — writing an ADR should take 10 minutes, not a morning.
* Greppable — decisions should live in the repo so they travel with the code.
* Explicit — every ADR names the options that were rejected and why.

## Considered options

* **MADR** — Markdown Architecture Decision Records. Short, structured, well-tooled.
* **Nygard format** — Original ADR shape. Less structured than MADR.
* **Free-form notes** — Blog posts in docs/. Least ceremony, no consistency.

## Decision outcome

Chosen option: **MADR**.

Because MADR is the current de-facto standard and renders nicely on GitHub. We ship [ADR-template.md](./ADR-template.md) and expect every accepted ADR to fill it in.

### Consequences

* Good: new engineers can scan the `decisions/` directory and get the "why" in order.
* Neutral: we commit to writing a new ADR for every technical choice the team cares about.
* Bad (accepted): a small upfront cost per decision. This is intentional — the cost is a filter.

## Validation

Every two months we review whether `decisions/` is being used. If it has fewer than a handful of new ADRs over that window while non-trivial tech decisions were made, we reconsider process.

## More information

* MADR spec: https://adr.github.io/madr/
* ADR intro from Michael Nygard: https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
