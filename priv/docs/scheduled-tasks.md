# Scheduled tasks (cron)

Run an agent on a recurring schedule. A task fires in a **fresh session with no chat
memory**, so its prompt must be self-contained (bake in the context, the data source,
the window). Manage tasks with the `schedule_task` tool.

## Create a task (`schedule_task`)

```
schedule_task create
  name: "Daily XML check"
  prompt: "Check the 06:00 XML load and report anything abnormal. ..."   (self-contained)
  schedule: "0 8 * * *"          (standard 5-field cron: 08:00 every day)
  timezone: "America/Sao_Paulo"  (any IANA name; omit for the configured default)
  model: <optional model override>
  deliver: "telegram:<chat_id>"  (or "none" to just keep the run history)
```

When created from a chat, `deliver` defaults to that same chat. Confirm the details
(what, when, timezone, where to report) with the user first.

## Other actions

- `list` — all tasks with their next run.
- `run id: <id>` — force a task now to preview it.
- `enable` / `disable` / `remove id: <id>`.
- `history id: <id>` — recent runs.

## Notes

- Schedule is a standard 5-field cron expression. Timezone is any IANA name — never
  hard-code it; use what the user asked (e.g. "6am German time" → `Europe/Berlin`).
- Tasks only fire while a long-running surface is up (`mix pepe serve` / `gateway`).
- Each due task runs in its own process, so many can fire at once without blocking.
