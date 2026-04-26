# Test fixtures

Canonical fixtures, referenced from `tests/bats/*.bats` and `evals/*.json`.
Keep each directory minimal — add only what a test actually needs to exercise the code path.

| Fixture | What it plants | Exercises |
|---|---|---|
| [empty/](./empty) | Nothing but a `.gitkeep` | No-manifest detection, extension-count fallback, 0-confidence path |
| [jsts-empty/](./jsts-empty) | `package.json` (next + react), `tsconfig.json`, `pnpm-lock.yaml` | JS/TS detector, husky installer, CLAUDE.md stack rendering |
| [python-empty/](./python-empty) | `pyproject.toml` (fastapi + [tool.uv]), `uv.lock` | Python detector, pre-commit.com installer, scaffold-docs on Python projects |
| [profiles/invalid-missing-stack.json](./profiles/invalid-missing-stack.json) | A negative profile (no top-level `stack`) | `validate-profile.sh` error path (exit 4) |
| [profiles/valid-minimal.json](./profiles/valid-minimal.json) | Smallest passing profile | `validate-profile.sh` success path + loader |
| [monorepo/](./monorepo) | `pnpm-workspace.yaml` + packages/api (fastapi) + packages/web (next) | Workspace iteration + polyglot aggregation |
| [go-empty/](./go-empty) | `go.mod` + `go.sum` + `main.go` (gin) | Go detector, `bin/install-hooks.sh --go` |
| [rust-empty/](./rust-empty) | `Cargo.toml` + `Cargo.lock` (axum) | Rust detector, `bin/install-hooks.sh --rust` |
| [rust-workspace/](./rust-workspace) | Root `Cargo.toml` with `[workspace]` + crates/core + crates/cli | Cargo workspace → `is_monorepo=true` |
| [legacy-with-drift/](./legacy-with-drift) | Partial `.gitignore`, non-CC history (via `seed.sh`) | `bin/compute-drift.sh`, `bin/retrofit.sh`, and doctor |

## Adding a fixture

1. Name it by the code path it exercises (`monorepo-pnpm/`, `django-legacy/`), not by what it
   contains. Fixtures age better when the name describes intent.
2. Only include files required by the test. Unused `node_modules` trees or vendor bundles are a
   maintenance tax and should never land here.
3. Document it in this table.
4. Reference it from the test file that needs it — fixtures with no references are candidates
   for removal.
