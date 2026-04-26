# Security Policy

## Reporting a vulnerability

If you find a security issue in **nyann**, please report it privately so we can ship a fix before it's public.

**Email:** thettweaung@gmail.com

Use the subject line `nyann security: <one-line summary>`. Encrypt with PGP only if you already have a key for that address — do not gate disclosure on key exchange. Plaintext is acceptable.

What to include:
- The version (commit SHA on `main` or release tag) you tested against
- Reproduction steps (smallest possible example — a profile fixture, a malformed git config, a hand-edited team source URL, etc.)
- The observed behaviour (RCE? file write outside the target repo? credential disclosure?)
- The behaviour you expected
- Your assessment of impact and exploitability (CRITICAL / HIGH / MEDIUM / LOW)

What to expect:
- **Acknowledgement within 72 hours** of receipt
- **Triage + first response within 7 days** with either (a) a confirmed reproducer + remediation timeline or (b) a documented reason the report does not constitute a vulnerability
- **Fix + advisory within 30 days** for HIGH and CRITICAL issues; MEDIUM/LOW may roll into the next release cadence
- Public credit in the release notes unless you ask to stay anonymous

## Scope

In scope:
- Anything under `bin/`, `hooks/`, `monitors/`, `profiles/`, `schemas/`, `templates/`, and `.github/workflows/`
- The skill layer's documented invocation contract (the `/nyann:*` slash commands and the natural-language triggers in each `skills/<name>/SKILL.md`)
- Profile JSON files at any tier (built-in starters, user, team-shared)

Out of scope:
- Third-party tools nyann delegates to (Husky, lint-staged, commitlint, pre-commit.com hooks, golangci-lint, ruff, gitleaks, etc.) — please report those upstream
- Vulnerabilities in `gh` or `git` themselves
- Issues that require an attacker to already have local code-execution as the user running nyann
- Issues in optional MCP servers (Obsidian, Notion) — report to the MCP server author

## Threat model assumptions

nyann is designed under these assumptions, and a finding that contradicts one of them is a real vulnerability:

1. **Untrusted profile inputs are validated before use.** A malicious team-source profile must not be able to achieve code execution, file write outside the target repo, or arbitrary git ref/URL substitution.
2. **`gh` integration is best-effort and never blocks.** If `gh` is missing, unauthenticated, or fails, nyann skips the GitHub operation with a logged reason — it never prompts for credentials.
3. **MCP boundary is one-directional.** Shell scripts under `bin/` never invoke MCP tools; only the skill layer does. A shell script that initiates an MCP call is a boundary violation regardless of intent.
4. **Preview-before-mutate.** Every destructive path emits an ActionPlan to `bin/preview.sh` and waits for explicit confirmation. A path that mutates without preview, or where the preview content differs from the executed content, is a vulnerability.
5. **Schemas are the contract.** Every JSON shape that crosses a layer boundary is described by a schema in `schemas/`. A producer that emits a shape outside its declared schema is a vulnerability if a consumer parses it; a consumer that accepts a shape outside the declared schema is a vulnerability if the new shape carries attacker-controlled data.

## Past disclosures

The `## [1.0.0]` section of `CHANGELOG.md` (under **Security**) summarises every security improvement that shipped in the initial release. Future findings will be listed in the matching released section with the disclosure credit.
