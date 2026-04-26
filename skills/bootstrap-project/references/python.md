# Python bootstrap notes

Load this file only when `detect-stack.sh` reports `primary_language == "python"`.

## Package manager

- `pyproject.toml` presence + `[tool.uv]` or `uv.lock` → uv. Prefer it if the user doesn't say
  otherwise; uv resolves + installs fastest.
- `poetry.lock` or `[tool.poetry]` → poetry. Don't switch to uv under a user who picked poetry.
- `Pipfile(.lock)` → pipenv. Mature projects rarely move off it; don't propose migration.
- Bare `requirements.txt` → pip. The hook installer still works; mention that migrating to
  `pyproject.toml` later is optional.

## Hook framework

- Always pre-commit.com for Python. Native `.git/hooks/` is only used for the `--core` phase
  when no stack-specific installer is available.
- `pre-commit install --install-hooks` runs from `bin/install-hooks.sh --python`. It needs
  network on first run to resolve hook envs.
- `bin/install-hooks.sh` prefers a user-installed `pre-commit` on PATH; falls back to
  `uvx pre-commit`. If neither is available, it emits a skip record — run `pip install pre-commit`
  and re-run the installer.

## Tooling choices in the default template

- **Ruff** does both lint and format. No separate Black.
- **commitizen** enforces Conventional Commits on the `commit-msg` stage. Use it instead of
  the native `commit-msg` regex when Python's the primary language.
- **gitleaks** is the shared secret scanner (same as JS/TS).

## Framework notes

- Django → consider an additional `pyproject.toml` scope called `migrations` and a pre-commit
  hook that fails if a migration file is edited without regenerating. Not shipped yet; flag for
  the user.
- FastAPI / Flask → no framework-specific hooks in v1. Python default template is enough.

## CLAUDE.md

- `run_command` is `(see your entry point)` for Python — there's no canonical dev command.
  Nudge the user to edit CLAUDE.md outside the nyann block with their actual entry point
  (`uvicorn app:main`, `python -m mypackage`, etc.).

## Common pitfalls

- Missing `.venv` on first run: the hook installer doesn't create one. If the user's pre-commit
  is installed in a venv, they need to activate it before running `pre-commit install`.
- Legacy `setup.py`-only repos: detection still works, but framework detection may miss deps
  declared via `install_requires=[...]` in a non-trivial expression. Mention this if relevant.
- `ruff` v0 vs v1 — the template pins v0.5; users who want to pin their own rev take precedence
  (merge keys on URL, not version).
