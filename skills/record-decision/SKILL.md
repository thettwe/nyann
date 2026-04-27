---
name: record-decision
description: >
  Append a new Architecture Decision Record (ADR) to the repo with an
  auto-incremented number and the MADR template.
  TRIGGER when the user says "record this decision", "log this
  decision", "add an ADR for X", "create an ADR about Y", "record the
  choice to use Postgres", "write up this decision", "document this
  as an ADR", "/nyann:record-decision".
  Do NOT trigger on "write a doc" / "add documentation" (those are
  broader — route to the appropriate doc skill). Do NOT trigger on
  "record a bug" / "open an issue" (those are GitHub concerns).
  Do NOT trigger on "what decisions have we made" (that's reading
  existing ADRs, not creating one).
---

# record-decision

Wraps `bin/record-decision.sh`. Creates one ADR file per invocation
under `docs/decisions/` (or the profile's configured location). Only
MADR format is supported in v1.

## 1. Collect inputs from the user

- **`--title`** (required). Short, imperative headline: *"Use Postgres
  for the primary datastore"*, *"Adopt pnpm over npm"*. If the user's
  phrasing is long and prose-y ("I think we should probably go with
  Postgres because…"), propose a crisp title and confirm.
- **`--status`**. `proposed` (default) when the decision is still up
  for review; `accepted` when the user says "we've already decided"
  or similar. Never default to `accepted` silently — when unclear,
  use `AskUserQuestion` to pick:

  - header: "Decision status"
  - options:
    - "Proposed (Default)" — decision is open for review
    - "Accepted" — decision has already been agreed upon
- **`--dir`**. Default `docs/decisions`. Override when the repo uses
  a different location (check the profile's
  `documentation.scaffold_types` if uncertain).
- **`--slug`** — derived from the title. Review the auto-derived slug
  with the user when the title contains non-ASCII or unusual
  punctuation.

## 2. Check for existing scaffolding

`record-decision` creates the directory if missing, but doesn't
scaffold a `README.md` or `ADR-000`. If the directory is empty (no
prior ADRs), mention that `bootstrap-project` scaffolds an introductory
`ADR-000` and offer to run it first — but proceed with the new ADR
either way if the user insists.

## 3. Dry-run first when the title is non-obvious

Run `bin/record-decision.sh --dry-run` and read back:

- The target path (which ADR number it'll land at).
- The derived slug.

Confirm before the real run. Single-line "record that we chose X"
phrasings can skip confirmation when the title is already explicit.

## 4. Invoke

```
bin/record-decision.sh --target <cwd> \
  --title "<imperative headline>" \
  [--status proposed|accepted] \
  [--dir <path>] \
  [--slug <slug>] \
  [--date YYYY-MM-DD] \
  [--dry-run]
```

## 5. After creation

The output JSON gives you the relative path. Offer to:

- Open the file so the user can fill in the sections (Context,
  Decision drivers, Considered options, Decision outcome,
  Consequences, Validation).
- Stage it for commit via `/nyann:commit` (suggest a commit subject
  like `docs(adr): ADR-NNN — <title>`).

Do NOT auto-fill the body from the user's conversation. An ADR's
value comes from the writer thinking through the structure; filling
it with Claude-generated prose dilutes that.

## 6. Number collisions

Numbers come from scanning `ADR-<NNN>-*.md` files in the target
directory. When the user has a non-conventional ADR naming scheme
(e.g. `0001-foo.md` without the `ADR-` prefix), the detector will
miss them and start at 000. If the user reports this, offer to
rename existing files or accept a manual `--dir` pointing at a
separate location.

## When to hand off

- "Show me existing ADRs" → `ls docs/decisions/` or a simple file
  listing; outside this skill.
- "Update an existing ADR" → this skill creates only. Supersedence
  is represented as a new ADR pointing at the old one (MADR
  convention).
- "Generate a changelog entry for this decision" → `release` skill
  handles CHANGELOG; ADRs and CHANGELOG are separate stores.
