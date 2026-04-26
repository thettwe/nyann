---
name: check-prereqs
description: >
  Survey the machine and report which nyann features are usable right now.
  TRIGGER when the user says "is my machine ready for nyann", "what do I
  need to install", "check my setup", "do I have the right tools",
  "check prereqs", "audit my environment", "new machine, what's missing",
  "I'm on a new machine", "install nyann prereqs", "/nyann:check-prereqs".
  Do NOT trigger on general "what is nyann" questions — those want a docs
  pointer, not a machine survey. Do NOT trigger when the user is already
  mid-bootstrap — let the bootstrap-project skill handle that case and
  emit its own skip records for missing stack tools.
---

# check-prereqs

Read-only environment survey. Never installs anything; never mutates the
filesystem. Flow:

1. Run `bin/check-prereqs.sh`. Default output is a human-readable table
   showing every prereq nyann touches, classified as **hard** (nyann
   exits 1 without it) or **soft** (feature-gated skip).
2. If the user passes the word `json` / "machine-readable" / similar,
   add `--json` so output is structured for scripting.
3. Exit code from the script is the signal:
   - `0` → all hard prereqs present. Soft misses are informational.
   - `1` → at least one hard prereq is missing. Tell the user explicitly
     that nyann cannot run yet, and point them at the install hint from
     the table.

## What to do after

- Soft misses aren't blockers, but each gates a specific feature. Offer
  to explain which feature needs which tool. Don't install anything on
  the user's behalf — just read the `hint` column back and let them decide.
- If the user asks "install these for me", decline politely — nyann
  doesn't bulk-install system packages. Direct them to the copy-pasteable
  install lines in the `hint` column.

## When to hand off

- User asks "OK, now bootstrap this repo" → route to the
  `bootstrap-project` skill.
- User asks "what does <tool> do in nyann?" → explain the feature(s) it
  gates (README has a table per soft dep).
