# _detect-common.sh — contract documentation for sourced detector modules.
#
# Each file under bin/detect-stack/ defines one or more detect_*() functions.
# The orchestrator (bin/detect-stack.sh) sources them and calls them in
# precedence order. Detectors read and write these shared globals:
#
#   path                  — repo root to inspect (read-only)
#   primary_language      — "unknown" | detected language string
#   secondary_languages_json — '[]' | JSON array of secondary languages
#   framework             — "null" | JSON-quoted framework string
#   package_manager       — "null" | JSON-quoted package manager string
#   signal_manifest       — 0|1 (explicit manifest found)
#   signal_claudemd       — 0|1 (CLAUDE.md hint found)
#   signal_docs           — 0|1 (doc hint found)
#   signal_lock           — 0|1 (lock file found)
#   signal_ext            — 0|1 (extension count fallback)
#   is_monorepo           — false|true
#   monorepo_tool         — "null" | JSON-quoted tool name
#   archetype             — "unknown" | detected archetype
#
# Functions also call add_reason() to accumulate detection reasoning.
# Return 0 on match, 1 on no-match.
#
# This file is NOT sourced — it's documentation only.
