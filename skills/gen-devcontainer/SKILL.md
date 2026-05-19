---
name: gen-devcontainer
description: >
  Generate a `.devcontainer/devcontainer.json` keyed to the project's
  primary language so `gh codespace create` (or VS Code's "Reopen in
  Container") gives anyone on the team a ready-to-go env with the
  right runtime, GH CLI, git-lfs, and language-tier VS Code
  extensions pre-installed. Preview-by-default; idempotent on apply
  (no-op on identical bytes, diff-and-refuse on divergence unless
  `--force-overwrite`).
  TRIGGER when the user says "add a devcontainer", "set up
  codespaces", "scaffold devcontainer.json", "reopen in container",
  "configure dev environment", "containerized dev env", "make this
  work in codespaces", "add VS Code container", "wire up
  devcontainer", "/nyann:gen-devcontainer". Also trigger when a user
  asks "how do I run this in Codespaces" and there's no
  `.devcontainer/` directory yet.
  Do NOT trigger on "build a Docker image for production" — that's
  a Dockerfile concern outside devcontainer scope. Do NOT trigger on
  "fix my devcontainer build" — that's debugging an existing setup,
  not generating one (read the file with the user instead).
arguments:
  - name: language
    description: Primary language — one of node, python, go, rust, dart, java, dotnet, php, ruby, swift, elixir, cpp. Maps from StackDescriptor.primary_language (typescript/javascript → node, csharp → dotnet).
  - name: name
    description: Devcontainer display name (surfaced in 'Open in Container' picker). Default is the repo basename when --target is supplied, otherwise `<language>-devcontainer`.
    optional: true
  - name: target
    description: Path to the repo. Required only when `--apply` is set.
    optional: true
  - name: apply
    description: Write the devcontainer.json to `<target>/.devcontainer/devcontainer.json`. Default is preview-to-stdout.
    optional: true
  - name: force-overwrite
    description: Overwrite an existing devcontainer.json whose content differs. Without it, the script prints a diff and exits 3.
    optional: true
  - name: port
    description: Repeatable. Forward a port from the container to the host (1-65535). Common picks - 3000/4200/5173 web dev, 8000/8080 APIs.
    optional: true
  - name: feature
    description: Repeatable. Extra devcontainer feature ref to merge onto the base set (gh CLI, git-lfs, common-utils). Always include a version pin.
    optional: true
  - name: extension
    description: Repeatable. Extra VS Code extension ID (`publisher.extension` format) to merge onto the per-language base set.
    optional: true
  - name: post-create-command
    description: Override the default per-language postCreateCommand. Empty string disables postCreateCommand entirely.
    optional: true
  - name: cpus
    description: Codespaces hostRequirements.cpus (2-32). Default unset (lets Codespaces pick).
    optional: true
  - name: memory
    description: Codespaces hostRequirements.memory (e.g. `4gb`, `8GiB`). Default unset.
    optional: true
  - name: storage
    description: Codespaces hostRequirements.storage (e.g. `16gb`, `32GiB`). Default unset.
    optional: true
---

# gen-devcontainer

Wraps `bin/gen-devcontainer.sh`. Emits a devcontainer.json; preview-
by-default; idempotent on apply.

## When to trigger

- User wants a Codespaces-ready repo and there's no `.devcontainer/`
  directory yet.
- User wants to refresh an existing devcontainer.json after upgrading
  nyann (base image tags + extension lists shift with the
  `snapshot_version` comment in the file).
- User wants to add forwarded ports / cpus / memory to an existing
  devcontainer (use `--port 3000 --cpus 4 --memory 8gb`).

## When NOT to trigger

- User wants a **production Dockerfile** — that's an entirely
  different concern; devcontainer.json is dev-environment only.
- User wants to **debug** a broken devcontainer build — open the
  existing file with them; this skill generates fresh, not diagnoses.
- User is on a non-Codespaces, non-VS Code editor — the file still
  works under JetBrains' Dev Containers plugin and `devcontainer
  open` (CLI), but flag the broader VS Code-first defaults.

## Picking the language

Read `StackDescriptor.primary_language` from `bin/detect-stack.sh`:

| StackDescriptor.primary_language | --language |
|---|---|
| `typescript` / `javascript` | `node` |
| `python` | `python` |
| `go` | `go` |
| `rust` | `rust` |
| `dart` | `dart` |
| `java` / `kotlin` | `java` |
| `csharp` / `dotnet` | `dotnet` |
| `php` | `php` |
| `ruby` | `ruby` |
| `swift` | `swift` |
| `elixir` | `elixir` |
| `cpp` / `c` | `cpp` |

For polyglot monorepos (`workspaces[]` present), pick the language of
the most-important workspace OR ask the user — running multiple
devcontainers from a single repo is uncommon and confusing.

## Preview, then apply

Always preview first. Show the rendered JSON; wait for confirmation:

```
bin/gen-devcontainer.sh --language python --name my-app
```

Then on confirmation:

```
bin/gen-devcontainer.sh --language python --name my-app \
  --target . --apply
```

If the destination already matches: log "unchanged" and exit. If it
differs: print the unified diff to stderr, exit 3, prompt the user
before re-running with `--force-overwrite`.

## Output shape

`.devcontainer/devcontainer.json` containing:

- `$schema` pointing at the official devcontainer spec
- `$comment` tagging the nyann snapshot version
- `name` (display name in 'Open in Container' picker)
- `image` (per-language, pinned to a major:minor tag)
- `features` (gh CLI, git-lfs, common-utils — version-pinned)
- `customizations.vscode.extensions` (per-language pack + gitlens + git-graph)
- `postCreateCommand` (per-language dep install — `npm ci`, `uv sync`, `cargo fetch`, etc.)
- `forwardPorts` (when `--port` flag(s) supplied)
- `hostRequirements` (when `--cpus` / `--memory` / `--storage` supplied)

## Defaults explained

- **Base image**: Microsoft devcontainers/<lang> images where they
  exist (well-maintained, security-scanned, multi-arch). Vendor
  images for Dart / Swift / Elixir where no MS variant exists.
- **Image tag**: pinned to `major:minor`, NOT a digest. Operators who
  need byte-reproducible builds should pin to a digest by hand; the
  Docker ecosystem of `gen-dependency-updater` can roll the tag.
- **Extensions**: per-language language pack + `gitlens` + `git-graph`
  baseline. Conservative pick; extend via `--extension`.
- **Features**: `github-cli:1` + `git-lfs:1` + `common-utils:2`,
  always with a version pin so floating tags can't quietly re-broadcast.
- **postCreateCommand**: best-effort install that no-ops when the
  expected manifest is missing (so the file works in a partially-
  scaffolded repo). Override with `--post-create-command` for non-
  standard package managers (e.g. pnpm rather than npm).

## Reading the output back

When previewing:
- Surface the base image (the operator may want to swap to an
  org-internal mirror).
- Surface the postCreateCommand (so they can spot install commands
  that don't fit their workflow).
- Suggest `--port` flags if the user mentioned a dev-server port in
  the conversation.

When applying:
- Confirm the dest path didn't already exist (or that the diff was
  intentional if `--force-overwrite` was used).
- Suggest a follow-up `gh codespace create` invocation if the user
  asked for Codespaces specifically.
