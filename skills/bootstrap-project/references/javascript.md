# JS / TS bootstrap notes

Load this file only when `detect-stack.sh` reports `primary_language == "typescript"` or
`"javascript"`.

## Package manager

- Prefer the lock file the repo already has (pnpm > yarn > bun > npm). Don't suggest changing it.
- If no lock file exists, nyann defaults to `npm install`. Offer pnpm if the user prefers it —
  they can add the lockfile before bootstrap.
- `bin/install-hooks.sh --jsts` does not run `npm install` itself; tell the user to run
  `<pm> install` after bootstrap, then `npx husky install`.

## Frameworks

- Next.js / Nuxt / Remix / SvelteKit → always suggest GitHub Flow; these are app/prototype stacks.
- A bare React / Vue lib (no meta-framework) could be either GHF or GitFlow depending on whether
  the project ships releases with a CHANGELOG. Trust `recommend-branch.sh`; don't override.

## Hook wiring

- Husky v9 is the pin in `templates/husky/commitlint.config.js`. If the repo already pins v8 in
  `devDependencies`, don't bump it; the hook files are compatible.
- Lint-staged config goes into `package.json` (not a separate file), so the diff shows up in the
  same PR that adds husky.
- `commitlint.config.js` is always at repo root. If the user later wants per-workspace rules,
  that's a monorepo concern — flag but don't solve.

## CLAUDE.md

- `install_command` / `run_command` / `test_command` / `lint_command` are inferred from the
  package manager by `bin/gen-claudemd.sh`. If the repo's scripts diverge (e.g. `yarn build`
  instead of `yarn dev`), that's fine — users will edit CLAUDE.md outside the nyann block.

## Common pitfalls

- Monorepos (`turbo.json` / `nx.json` / `pnpm-workspace.yaml`) — nyann detects workspaces and
  generates per-workspace lint-staged entries, commit scopes, and a Workspaces table in CLAUDE.md.
  Profile-level workspace overrides can customize per-package hook lists.
- Yarn Berry (`.yarnrc.yml` + `.pnp.cjs`) — hook install still works but Berry's install model
  is different from classic yarn. Don't assume `yarn install` is idempotent across versions.
- If `.husky/` exists but was installed by husky v4 (pre-v7), migration is on the user.
