---
name: gen-dependency-updater
description: >
  Generate a Dependabot or Renovate config (`.github/dependabot.yml`
  or `renovate.json`) for the active stack with sensible defaults
  (weekly schedule, minor+patch grouping, open-PR cap at 5). Preview-
  before-mutate: prints the rendered config and exits without writing
  unless `--apply` is passed. Idempotent: same content is a no-op,
  different content shows a diff and refuses to overwrite without
  `--force-overwrite`.
  TRIGGER when the user says "add dependabot", "enable dependabot",
  "add renovate", "set up renovate", "configure dependency updates",
  "automate dependency updates", "scaffold dependabot.yml", "create
  renovate.json", "add automated dependency PRs", "wire dependency
  bot", "turn on dependency updates", "/nyann:gen-dependency-updater".
  Do NOT trigger on "update my dependencies" / "run npm update" —
  that's a one-off package-manager invocation, not config scaffolding.
  Do NOT trigger on "fix this dependabot PR" — that's a workflow
  inside a specific PR, not config generation.
arguments:
  - name: updater
    description: Which generator to emit — `dependabot` (per-ecosystem YAML) or `renovate` (single JSON using `config:recommended`).
  - name: ecosystem
    description: Repeatable. Dependabot's `package-ecosystem` value (npm / pip / gomod / cargo / bundler / composer / maven / gradle / pub / nuget / mix / swift / docker / github-actions). `npm` covers npm/pnpm/yarn/bun. For monorepos pair with `--directory` per workspace.
  - name: directory
    description: Repo-relative directory of the manifest, must start with `/`. Default `/` (repo root). When `--ecosystem` repeats, place `--directory` BEFORE the corresponding `--ecosystem` to associate them.
    optional: true
  - name: target
    description: Path to the repo. Required only when `--apply` is set; preview mode doesn't need it.
    optional: true
  - name: apply
    description: Write the config to the destination path. Without it, the rendered config is printed to stdout (preview).
    optional: true
  - name: force-overwrite
    description: Overwrite an existing config whose content differs from the rendered output. Without it, the script prints a diff and exits with code 3.
    optional: true
  - name: schedule
    description: How often the updater polls — `daily`, `weekly` (default), or `monthly`.
    optional: true
  - name: grouping
    description: How to bundle updates — `off` (one PR per update), `minor-patch` (default, groups minor+patch, keeps majors separate), `all` (group everything).
    optional: true
  - name: open-prs
    description: Max open dependency-updater PRs per ecosystem (1-25, default 5).
    optional: true
---

# gen-dependency-updater

Wraps `bin/gen-dependency-updater.sh`. Emits a Dependabot or Renovate
config; preview-by-default; idempotent on apply.

## When to trigger

- User wants automated dependency PRs and doesn't already have either
  config wired up.
- User wants to migrate Dependabot ↔ Renovate.
- User wants to re-generate the config after upgrading nyann (the
  template defaults shift with each `snapshot_version`).

## When NOT to trigger

- User wants to **manually upgrade** a specific dep — that's
  `npm install`, `pip install -U`, `cargo update`, etc.
- User wants help **resolving** a Dependabot/Renovate PR — read the
  PR diff with them; this skill is for config generation only.
- User is in a non-GitHub forge — Dependabot is GitHub-specific.
  Renovate runs anywhere but its app installation is out of scope
  for this skill.

## Picking updater (when the user hasn't specified)

Default to **dependabot** when:
- The repo is on GitHub (which is nyann's `gh`-integration assumption).
- The user wants minimal moving parts (Dependabot is native to GH,
  no app to install).

Default to **renovate** when:
- The user mentions multi-platform forge support.
- The user wants advanced grouping / customization (Renovate's
  package rules are richer than Dependabot's `groups`).
- The user is already a Renovate user on other repos.

When in doubt, ask:
> "Dependabot is GitHub-native and zero-install — recommended for
> most. Renovate is more configurable but requires installing the
> Renovate GitHub App. Which do you want?"

## Picking ecosystems

Read the StackDescriptor (from `bin/detect-stack.sh`) and map:

| Stack hint | Ecosystem(s) |
|---|---|
| `primary_language=typescript` / `javascript` | `npm` |
| `primary_language=python` | `pip` |
| `primary_language=go` | `gomod` |
| `primary_language=rust` | `cargo` |
| `primary_language=ruby` | `bundler` |
| `primary_language=php` | `composer` |
| `primary_language=java` (Maven) | `maven` |
| `primary_language=java` (Gradle) / `kotlin` | `gradle` |
| `primary_language=dart` | `pub` |
| `primary_language=csharp` / `dotnet` | `nuget` |
| `primary_language=elixir` | `mix` (v1.10+) |
| `primary_language=swift` | `swift` |
| `Dockerfile` present | `docker` (in addition to language ecosystem) |
| `.github/workflows/` present | `github-actions` (always recommended) |

Always include `github-actions` even when the user didn't ask — it
keeps the SAST workflow pins current.

For monorepos (`workspaces` resolved by `bin/resolve-workspace-configs.sh`),
emit one `--ecosystem` per workspace with the workspace path as
`--directory`. Dependabot doesn't auto-walk; one entry per manifest
is mandatory.

## Preview, then apply

Always preview first. Even if the user said "just do it", show the
rendered config and wait for confirmation:

```
bin/gen-dependency-updater.sh --updater dependabot --ecosystem npm --ecosystem github-actions
```

Then on confirmation:

```
bin/gen-dependency-updater.sh --updater dependabot \
  --ecosystem npm --ecosystem github-actions \
  --target . --apply
```

If the destination file already exists and matches: log "unchanged"
and exit. If it differs: print diff, exit 3, prompt the user before
re-running with `--force-overwrite`.

## Output

- `.github/dependabot.yml` (Dependabot)
- `renovate.json` (Renovate, at repo root)

Both files include a comment header tagging the nyann version that
generated them, so a future operator can tell when to regenerate.

## Defaults explained

- **Schedule = weekly**: Daily is noisy for most teams; monthly lets
  CVEs sit. Weekly balances responsiveness vs. PR-fatigue.
- **Grouping = minor-patch**: Bundles minor + patch into one PR per
  ecosystem (review-friendly). Majors stay separate because they
  often need breaking-change review regardless of patch size.
- **open-prs = 5**: Enough headroom for routine churn; raise for
  high-velocity repos.
- **Labels = `dependencies`, `automated`**: `automated` lets you opt
  these out of expensive CI matrices via label filters.

Override any of these via the corresponding flags.
