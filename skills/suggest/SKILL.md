---
name: suggest
description: "Analyze a repository and suggest profile updates. TRIGGER ON: 'suggest profile changes', 'what should I add to my profile', 'profile recommendations', 'analyze my hooks', 'detect missing hooks', 'suggest improvements', 'profile audit', 'what tools am I missing', 'check profile coverage', 'profile gaps'. Scans devDependencies, config files, repo structure, and git history to find mismatches with the active nyann profile."
---

# suggest — Smart Profile Suggestions

You are the suggest skill. You analyze a repository's actual state (dependencies, config files, structure, git history) against the active nyann profile and recommend updates.

## When to trigger

- User asks what they should add to their profile
- User wants to check if their profile covers all installed tools
- User asks about profile gaps, missing hooks, or coverage
- After bootstrap or retrofit, to suggest profile refinements
- User asks "what tools am I missing" or "audit my profile"

**DO NOT trigger on:** general profile questions (use inspect-profile), profile creation (use learn-profile), or switching between profiles (use migrate-profile).

## Execution flow

### Phase 1: Detect stack and resolve profile

1. Run `bin/detect-stack.sh --path .` to get a StackDescriptor JSON.
2. Resolve the active profile:
   - Check `~/.claude/nyann/preferences.json` for a profile name
   - Fall back to CLAUDE.md markers (`<!-- nyann:start -->` block → profile name)
   - Fall back to `"default"`
3. Load the profile via `bin/load-profile.sh <profile-name>`.

### Phase 2: Run the suggestion engine

4. Run `bin/suggest-profile-updates.sh --profile <profile-path> --target . --stack <stack-path>`.
5. Parse the JSON array of suggestions.

### Phase 3: Present suggestions

6. Group suggestions by category and present them in a clear table:
   - **hook-gap**: Tool installed but not hooked (high confidence)
   - **config-present**: Config file exists but tool not hooked
   - **structure**: Monorepo signals detected
   - **history-drift**: Commit format doesn't match profile setting
   - **scope-gap**: Commit scopes used but not declared in profile

7. For each suggestion, show:
   - What was detected (the signal)
   - What to change (the suggestion)
   - Confidence level (0.0–1.0)

### Phase 4: Offer to apply

8. Ask the user which suggestions to apply.
9. For actionable suggestions (those with `action.field` and `action.add`), offer to update the profile JSON directly.
10. After applying, suggest running `/nyann:doctor` to verify the changes.

## Key constraints

- Suggestions are advisory — never auto-apply without user confirmation.
- Confidence thresholds: only show suggestions with confidence >= 0.5.
- Git history analysis uses the last 50 commits as a sample.
- Deduplication: if a tool appears in both devDependencies and config signals, only one suggestion is emitted.

## Error handling

- No package.json → skip devDependencies analysis (not an error)
- Not a git repo → skip history analysis, warn user
- No profile found → use `default` profile, note in output
- All signals empty → report "no suggestions — profile looks complete"

## When to hand off

- "Apply these suggestions to the profile" → edit the profile JSON
  directly (phase 4 above), then suggest `/nyann:doctor` to verify.
- "Switch to a completely different profile" → `migrate-profile` skill.
- "Check if my repo is healthy after these changes" → `doctor` skill.
- "What does the current profile look like?" → `inspect-profile` skill.
