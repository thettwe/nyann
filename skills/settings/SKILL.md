---
name: settings
description: >
  Interactive settings menu for nyann preferences. View current values
  in a table, then pick one setting to change at a time via
  AskUserQuestion. Re-runnable anytime — does not require a full setup
  wizard.
  TRIGGER when the user says "change nyann settings", "nyann
  preferences", "configure nyann settings", "update my preferences",
  "toggle triage", "disable sentinel", "enable session triage",
  "/nyann:settings", "show nyann settings", "nyann config".
  ALSO trigger on direct shortcut: "/nyann:settings <key> <value>" —
  skip the menu and write the value directly.
  Do NOT trigger on "/nyann:setup" — that is the first-run wizard.
  Do NOT trigger on "/nyann:check-prereqs" — that inspects host tools,
  not nyann config.
---

# settings

> **CRITICAL**: This skill uses `AskUserQuestion` for every choice.
> **NEVER ask the user questions as plain text.**

**Script paths:** nyann is a Claude Code plugin. Plugin root is two
levels above this SKILL.md (`<plugin_root>/skills/settings/SKILL.md`).
All scripts live at `<plugin_root>/bin/`.

## Step 0: Verify setup ran

Run `bash <plugin_root>/bin/setup.sh --check --json`. If
`status != "configured"`, hand off to the `setup` skill — settings
edits a file that doesn't exist yet.

## Step 1: Direct shortcut path

If the user typed `/nyann:settings <key> <value>` (or otherwise gave
both a key and a value in natural language), skip the menu and run:

```
bash <plugin_root>/bin/settings.sh --set <key> <value>
```

Surface the one-line confirmation and stop. No further prompts.

## Step 2: Show current preferences

Run `bash <plugin_root>/bin/settings.sh --show` and render the output
as a markdown table:

```
| Setting                          | Value                       |
|----------------------------------|-----------------------------|
| Default profile                  | auto-detect                 |
| Branching strategy               | auto-detect                 |
| Commit format                    | conventional-commits        |
| GitHub CLI                       | enabled                     |
| Documentation storage            | local                       |
| Auto-sync team profiles          | off                         |
| Session triage                   | enabled                     |
| Guard severity (default)         | advisory                    |
| CI sentinel notifications        | enabled                     |
| Staleness alerts                 | enabled                     |
| Git identity                     | Name <email>                |
```

## Step 3: Ask which setting to change

Call `AskUserQuestion` with options listing each setting. Add a final
"Done — no changes" option:

AskUserQuestion caps the options array at 4 entries per question, so present
the picker in two passes: first ask the user which group of settings to
explore, then ask which specific setting in that group to change.

Pass 1 — group picker:

```json
{
  "questions": [
    {
      "question": "Which group of settings would you like to change?",
      "header": "Group",
      "multiSelect": false,
      "options": [
        { "label": "Core (profile, branching, commits, GitHub CLI)", "description": "Day-to-day defaults" },
        { "label": "Documentation + team sync",                       "description": "Docs storage, auto-sync of team profile sources" },
        { "label": "Proactive features (triage, guards, notifications)", "description": "Awareness + monitoring toggles" },
        { "label": "Done — no changes",                                "description": "Exit without writing" }
      ]
    }
  ]
}
```

Pass 2 — based on the group, ask the specific setting:

**Core group:**
```json
{
  "questions": [{
    "question": "Which core setting would you like to change?",
    "header": "Setting",
    "multiSelect": false,
    "options": [
      { "label": "Default profile",    "description": "Stack-aware preference for which profile to apply" },
      { "label": "Branching strategy", "description": "github-flow | gitflow | trunk-based | auto-detect" },
      { "label": "Commit format",      "description": "conventional-commits | custom" },
      { "label": "GitHub CLI",         "description": "enabled | disabled (branch protection, PR helpers)" }
    ]
  }]
}
```

**Documentation + team sync group:**
```json
{
  "questions": [{
    "question": "Which documentation / team-sync setting?",
    "header": "Setting",
    "multiSelect": false,
    "options": [
      { "label": "Documentation storage",   "description": "local | obsidian | notion" },
      { "label": "Auto-sync team profiles", "description": "Auto-sync team profile sources during bootstrap" }
    ]
  }]
}
```

**Proactive features group:**
```json
{
  "questions": [{
    "question": "Which proactive-feature toggle?",
    "header": "Setting",
    "multiSelect": false,
    "options": [
      { "label": "Session triage",                "description": "Quiet drift check on first message each session" },
      { "label": "Guard severity (default)",      "description": "advisory | confirm — pre-action guard severity floor" },
      { "label": "Notifications (sentinel/staleness)", "description": "In-session CI sentinel + doc staleness toggles" },
      { "label": "Notification delivery",         "description": "Send alerts to Slack/Discord/webhook/email" }
    ]
  }]
}
```

If the user picks **Notifications (sentinel/staleness)**, ask which of the two
in-session toggles to change (CI sentinel notifications | Staleness alerts),
then go to Step 4 for that toggle.

If the user picks **Notification delivery**, run the delivery sub-flow
(Step 3a) below instead of Step 4 — delivery channels are multi-field, not a
single enum.

### Step 3a: Notification delivery sub-flow

External delivery fans queued notifications out to Slack, Discord, a generic
webhook, or email. First pick the channel:

```json
{
  "questions": [{
    "question": "Which delivery channel?",
    "header": "Channel",
    "multiSelect": false,
    "options": [
      { "label": "Slack",   "description": "Incoming webhook ({text: ...})" },
      { "label": "Discord", "description": "Webhook ({content: ...})" },
      { "label": "Webhook", "description": "Generic endpoint — raw JSON POST" },
      { "label": "Email",   "description": "sendmail or an SMTP relay" }
    ]
  }]
}
```

Then, **because delivery secrets must never live in `preferences.json`**, ask
for the *name of an environment variable* that holds the endpoint URL — never
the URL itself. Tell the user to `export NYANN_SLACK_WEBHOOK=https://...` in
their shell profile, then store only the name here. Set the channel with the
direct `--set` calls (one per field):

- Slack:   `notifications.delivery.slack.webhook_url_env <ENV_NAME>` then
  `notifications.delivery.slack.enabled true`
- Discord: `notifications.delivery.discord.webhook_url_env <ENV_NAME>` then
  `notifications.delivery.discord.enabled true`
- Webhook: `notifications.delivery.webhook.url_env <ENV_NAME>` then
  `notifications.delivery.webhook.enabled true`
- Email:   `notifications.delivery.email.to <addr>`,
  `notifications.delivery.email.from <addr>`, optional
  `notifications.delivery.email.smtp_env <ENV_NAME>`, then
  `notifications.delivery.email.enabled true`

`bin/settings.sh` REFUSES any value that looks like a URL (`http(s)://`) for a
delivery key and prints why — surface that error verbatim and re-ask for the
env-var NAME. After writing, return to Step 6.

(If the user expressed interest in a specific setting in their initial
message — e.g., "toggle triage" — go straight to that setting's value
picker without showing the group menu.)

## Step 4: Ask for the new value

Once the user picks a setting, call `AskUserQuestion` with the valid
values for that setting (see `bin/settings.sh` for the enums). Example
for **Session triage**:

```json
{
  "questions": [
    {
      "question": "Enable session-start drift triage?",
      "header": "Session triage",
      "multiSelect": false,
      "options": [
        { "label": "Enabled (Recommended)", "description": "Quiet drift check on first message each session" },
        { "label": "Disabled",              "description": "Skip the check; rely on /nyann:doctor manually" }
      ]
    }
  ]
}
```

## Step 5: Write the value

Map the picker choice to the `--set <key> <value>` invocation. Key/value
table:

| Setting                  | Key                            | Values                                              |
|--------------------------|--------------------------------|-----------------------------------------------------|
| Default profile          | `default_profile`              | `auto-detect` or `<profile-name>`                   |
| Branching strategy       | `branching_strategy`           | `auto-detect`, `github-flow`, `gitflow`, `trunk-based` |
| Commit format            | `commit_format`                | `conventional-commits`, `custom`                    |
| GitHub CLI               | `gh_integration`               | `true`, `false`                                     |
| Documentation storage    | `documentation_storage`        | `local`, `obsidian`, `notion`                       |
| Auto-sync team profiles  | `auto_sync_team_profiles`      | `true`, `false`                                     |
| Session triage           | `session_triage`               | `true`, `false`                                     |
| Guard severity (default) | `guard_default_severity`       | `advisory`, `confirm`                               |
| CI sentinel              | `notifications.sentinel`       | `true`, `false`                                     |
| Staleness alerts         | `notifications.staleness_alerts` | `true`, `false`                                   |
| Slack delivery on/off    | `notifications.delivery.slack.enabled`   | `true`, `false`                           |
| Slack endpoint env name  | `notifications.delivery.slack.webhook_url_env`   | env-var NAME (e.g. `NYANN_SLACK_WEBHOOK`) |
| Discord delivery on/off  | `notifications.delivery.discord.enabled` | `true`, `false`                           |
| Discord endpoint env name| `notifications.delivery.discord.webhook_url_env` | env-var NAME                      |
| Webhook delivery on/off  | `notifications.delivery.webhook.enabled` | `true`, `false`                           |
| Webhook endpoint env name| `notifications.delivery.webhook.url_env` | env-var NAME                              |
| Email delivery on/off    | `notifications.delivery.email.enabled`   | `true`, `false`                           |
| Email recipient          | `notifications.delivery.email.to`        | address                                   |
| Email sender             | `notifications.delivery.email.from`      | address                                   |
| Email SMTP relay env name| `notifications.delivery.email.smtp_env`  | env-var NAME (optional; else `sendmail`)  |

Run:
```
bash <plugin_root>/bin/settings.sh --set <key> <value>
```

## Step 6: Loop or exit

After the write succeeds, show the updated row and call
`AskUserQuestion` once more: "Change another setting?" → If yes, jump
to Step 3. If no, print a short confirmation and exit.

## Notes

- The script validates every value against the schema; if it rejects,
  surface the error verbatim and re-ask the picker.
- This skill **never** modifies `git_identity` interactively — git
  identity is set once at setup time. Edit it via the direct shortcut:
  `/nyann:settings git_identity.name "Foo Bar"`.
- For first-time users with no `preferences.json`, hand off to the
  `setup` skill instead of trying to construct the file from scratch.
- **Delivery secrets are never stored.** The `notifications.delivery.*`
  `*_env` keys hold only the NAME of an environment variable; nyann reads the
  actual URL/token from that env var at delivery time. `bin/settings.sh`
  rejects any literal `http(s)://` value for a delivery key — if it does, the
  user pasted a URL where an env-var name belongs. Setting any delivery key
  upgrades the file to schemaVersion 3.
