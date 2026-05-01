---
name: diff-profile
description: >
  Compare two nyann profiles side-by-side and show what would change.
  TRIGGER ON: 'diff profiles', 'compare profiles', 'what's different between profiles',
  'profile diff', 'diff default vs nextjs', 'compare default and python-cli',
  'what would change if I switch profiles', 'show me the difference between profiles',
  'how does X profile differ from Y', 'what hooks does X add over Y',
  'profile comparison', '/nyann:diff-profile'.
  Do NOT trigger on "switch profile" / "migrate profile" — those are migrate-profile.
  Do NOT trigger on "inspect profile" / "what does this profile do" — those are inspect-profile.
---

# diff-profile — Compare Two Profiles

You are the diff-profile skill. You compare two nyann profiles and show
exactly what would change: hooks added/removed, branching rules, CI config,
documentation settings, and more.

## When to trigger

- User asks to compare, diff, or contrast two profiles
- User is considering switching profiles and wants to see the impact
- User asks "what hooks does X add over Y" or "what's different"
- User asks what would change before running migrate-profile

**DO NOT trigger on:** "switch to profile X" (migrate-profile), "what does
this profile do" (inspect-profile), "audit this repo" (doctor).

## Execution flow

### 1. Resolve the two profiles

The user must name two profiles. Common patterns:

- Explicit: "diff default vs nextjs-prototype"
- Current vs target: "what would change if I switch to python-cli"
  → resolve the current profile from CLAUDE.md / preferences, then diff
  current vs the named target.
- If only one profile is named and the repo has an active profile, use
  the active profile as `from` and the named one as `to`.
- If you can't determine both, ask: "Which two profiles should I compare?"

### 2. Run the diff

```
bin/diff-profile.sh <from> <to>
```

Both arguments are **bare profile names** (e.g. `default`, `python-cli`),
not filesystem paths. The script resolves them via `load-profile.sh`.

### 3. Present the results

Show a section-by-section summary. Focus on what the user cares about:

- **Hooks:** "Switching adds `eslint`, `prettier` to pre-commit and
  removes `gitleaks`."
- **Branching:** "Strategy changes from github-flow to gitflow."
- **CI:** "CI generation gets enabled."
- **Documentation:** "Scaffold types gain `prd` and `research`."

If `identical` is true, say so: "These profiles are identical."

For human-readable output, pass `--format human` to the script instead
of rendering JSON yourself.

### 4. Suggest next steps

- "Want to switch? Run `/nyann:migrate-profile` to apply the change."
- "Want to inspect either profile in detail? Run `/nyann:inspect-profile <name>`."
- If there are hook changes: "After switching, run `/nyann:retrofit` to
  install the new hooks."

## Error handling

- Profile not found → show the available profiles list from load-profile.sh's
  error output and ask the user to pick a valid name.
- Same profile named twice → "Both profiles are the same. Nothing to diff."

## When to hand off

- "Switch to this profile" → `migrate-profile`.
- "Tell me about this profile" → `inspect-profile`.
- "Apply these changes" → `retrofit`.
- "Bootstrap with this profile" → `bootstrap-project`.
