# Tests

Two tiers:
- **bats** (shell-native) for bin/ script behavior and fixture assertions.
- **shellcheck** + SKILL.md line count via `tests/lint.sh` for static quality.

Eval-tier tests (skill trigger + output-quality) live under `evals/` — see
[`evals/README.md`](../evals/README.md).

## Run

```sh
# Quality lint
./tests/lint.sh

# Unit + integration
bats tests/bats
```

## Prereqs

- [bats-core](https://bats-core.readthedocs.io/) — `brew install bats-core`
- [shellcheck](https://www.shellcheck.net/) — `brew install shellcheck`
- `uvx` or `check-jsonschema` for the schema-validation tests (auto-detected)

The profile-merge Python helper for pre-commit configs uses `python3` + `PyYAML`.
These come with most dev machines; `brew install python` if missing.

## Layout

```
tests/
├── README.md
├── lint.sh                     # shellcheck + SKILL line-count
├── bats/
│   ├── test-detect.bats
│   ├── test-recommend.bats
│   ├── test-profile-schema.bats
│   ├── test-install-hooks.bats
│   └── test-skill-length.bats
└── fixtures/                   # see fixtures/README.md
```

## CI

GitHub Actions runs `./tests/lint.sh` + `bats tests/bats` on every PR.
Config lands with M6 (see docs/tasks/M6-marketplace-polish.md).
